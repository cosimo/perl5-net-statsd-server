package Net::Statsd::Server;

# Use statements {{{
use strict;
use warnings;

use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Log;
use AnyEvent::Socket;

use Data::Dump;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use JSON::XS ();
use POSIX qw(:errno_h :sys_wait_h);
use Time::HiRes ();

# }}}

# Constants {{{

use constant {
    DEBUG                  => 1,
    DEFAULT_CONFIG_FILE    => 'dConfig.js',
    DEFAULT_FLUSH_INTERVAL => 10,
    DEFAULT_LOG_LEVEL      => 'notice',
};

# }}}

# AnyEvent logging setup {{{

$AnyEvent::Log::FILTER->level(DEFAULT_LOG_LEVEL);

# Syslog logging works commenting out the FILTER->level line
$AnyEvent::Log::COLLECT->attach(
    AnyEvent::Log::Ctx->new(
        level         => "critical",
        log_to_syslog => "user",
    )
);

# }}}

# Signals handling {{{

$SIG{HUP} = \&reload_config;

# }}}

my $start = [ Time::HiRes::gettimeofday ];
my $flush_interval = 1;

sub new {

  my $startup_time = time();

  # Initialize data structures with defaults for statsd stats
  my $srv_context = {
    keyCounter => {},
    counters   => {
      "statsd.packets_received" => 0,
      "statsd.bad_lines_seen"   => 0,
    },
    stats => {
      messages => {
        "last_msg_seen"  => $startup_time,
        "bad_lines_seen" => 0,
      }
    },
    timers        => {},
    gauges        => {},
    sets          => {},
    counter_rates => {},
    timer_data    => {},
    pctThreshold  => undef,
    startup_time  => scalar(time()),
    backendEvents => [],
    debugInt      => undef,
    flushInterval => undef,
    keyFlushInt   => undef,
    server        => undef,
    mgmtServer    => undef,
    config        => undef,
    logger        => sub { warn(@_); },
  };

  my $self = {
    server_context => $srv_context,
    startup_time   => $startup_time,
  };

  bless $self;
}

sub _setup_timers {
  my ($self) = @_;

  my $flush_interval = $self->config->{flushInterval}
    || DEFAULT_FLUSH_INTERVAL;

  $self->{_timers}->{flush} =
    AE::timer $flush_interval, $flush_interval, \&flush_metrics;
  return;
}

sub config_defaults {
  return {
    "debug" => 0,
    "debugInterval" => 10000,      # ms
    "graphitePort" => 2003,
    "port" => 8125,
    "address" => "0.0.0.0",
    "mgmt_port" => 8126,
    "mgmt_address" => "0.0.0.0",
    "flushInterval" => 10000,      # ms
    "keyFlush" => {
      "interval" => 10,            # s
      "percent"  => 100,
      "log"      => "",            # FIXME What's this?
    },
    "log" => {
    },
    "percentThreshold" => 90,
    "dumpMessages" => 0,
    "backends" => [
      "Net::Statsd::Backend::Graphite"
    ],
  };
}

sub config {
  my ($self, $config_file) = @_;

  $config_file ||= $self->default_config_file();

  if (! -e $config_file) {
    return;
  }

  my $defaults = $self->config_defaults();

  open my $conf_fh, '<', $config_file
    or return $defaults;

  my $conf_json = join("", <$conf_fh>);
  close $conf_fh;

  my $json = JSON::XS->new->relaxed->utf8;
  my $conf_hash = $json->decode($conf_json);

  # Poor man's Hash::Merge
  for (keys %{ $defaults }) {
    if (! exists $conf_hash->{$_}) {
      $conf_hash->{$_} = $defaults->{$_};
    }
  }

  return $conf_hash;

}

sub default_config_file {
  return DEFAULT_CONFIG_FILE;
}

sub start_server {
  my ($self, $config) = @_;

  if (! defined $config) {
    $config = $self->config();
  }

  my $host = $config->{address} || '0.0.0.0';
  my $port = $config->{port}    || 8125;

  my $mgmt_host = $config->{mgmt_address} || '0.0.0.0';
  my $mgmt_port = $config->{mgmt_port}    || 8126;

  AnyEvent::Socket::tcp_server(
    '0.0.0.0', 8125,
    #$host => $port,
    sub { incoming_statsd_connection($self, @_) },
  );

  AnyEvent::Socket::tcp_server(
    $mgmt_host => $mgmt_port,
    sub { incoming_manager_connection($self, @_) },
  );

  AE::log notice => "statsd server starting on ${host}:${port} (${AnyEvent::MODEL})";
  AE::log notice => "manager interface on ${mgmt_host}:${mgmt_port})";

  my $cv = AE::cv;
  $cv->recv();

}

sub delete_client {
  my $client_info = shift;
  $client_info->{handle}->destroy();
  delete @$client_info{qw(handle fh fd)};
}

sub flush_metrics {
  my (@shit) = @_;
  AE::log warn => join("", @shit);
  my $TimeTaken = Time::HiRes::tv_interval($start);
  AE::log warn => "Elapsed time since start: $TimeTaken";
}

sub handle_packet {
  my ($self, $client_info) = @_;

  my $request = $client_info->{request};
  my ($cmd, @args) = split m{,}, $request;

  my $handle = $client_info->{handle};
  AE::log warn => "(statsd) handle=$handle";

  if ($cmd ne 'x') {
    reply($client_info, $cmd);
  } else {
    warn "Bad command - $cmd";
    delete_client($client_info);
  }
}

sub incoming_statsd_connection {
  my ($self, $fh) = @_;

  my $client_info = {
    fh => $fh,
    fd => fileno($fh),
    connect_time => time(),
  };

  AE::log notice => "Got client connection: $client_info->{fd}";

  my $handle = AnyEvent::Handle->new(
    fh => $fh,
    on_error => sub { on_socket_error($client_info, @_) },
  );
  AE::log notice => "(statsd) Created new AE handle: $handle";

  $client_info->{handle} = $handle;
  AE::log notice => "About to wait for a line";

  $handle->push_read(line => sub {
    my (undef, $request) = @_;
    warn("Read command from client cfd=$client_info->{fd}: $request");
    $client_info->{request} = $request;
    handle_packet($self, $client_info);
  });
}

sub incoming_manager_connection {
  my ($self, $fh) = @_;

  my $client_info = {
    fh => $fh,
    fd => fileno($fh),
    connect_time => time(),
  };

  AE::log notice => "Got manager connection: $client_info->{fd}";

  my $handle = AnyEvent::Handle->new(
    fh => $fh,
    on_error => sub { on_socket_error($client_info, @_) },
  );
  AE::log notice => "(mgmt) Created new AE handle: $handle";

  $client_info->{handle} = $handle;
  AE::log notice => "About to wait for a line";

  $handle->push_read(line => sub {
    my (undef, $request) = @_;
    warn("Read mgmt command from client cfd=$client_info->{fd}: $request");
    $client_info->{request} = $request;
    handle_management_command($self, $client_info);
  });
}

sub on_socket_error {
  my ($client_info, undef, $fatal, $msg) = @_;
  if ($! == EPIPE) {
    my $open_time = time() - $client_info->{connect_time};
    warn("Client dropped connection fd=$client_info->{Fd} after $open_time seconds");
  }
  else {
    warn("Got error '$msg' on client connection fd=$client_info->{fd}");
  }
  warn("Client request was: $client_info->{request}");
  delete_client($client_info);
}

sub reload_config {
}

sub reply {
  my ($client_info, $reply) = @_;

  my $client_handle = $client_info->{handle}
    or die "Undefined client handle for fd=$client_info->{fd}";

  $client_handle->push_write($reply);
  $client_handle->push_shutdown();

  # Cleanup all references once we've written the response
  $client_handle->on_drain(sub {
    $client_handle = undef;
    delete_client($client_info);
  });
}

sub handle_management_command {
    my ($self, $client_info) = @_;
    my $data = $client_info->{request};
    my @cmdline = split(" ", trim($data));
    my $cmd = shift @cmdline;
    if ($cmd eq "help") {
        reply($client_info,
          "Commands: stats, counters, timers, gauges, delcounters, deltimers, delgauges, quit\n\n"
        );
    }
    elsif ($cmd eq "stats") {
        my $now    = time;
        my $uptime = $now - $self->{startup_time};
        my $reply = "uptime: $uptime\n";

        # Loop through the base stats
        my $stats = $self->stats;

        for my $group (keys %{$stats}) {
          for my $metric (keys %{$stats->{$group}}) {
            my $val = $stats->{$group}->{$metric};
            my $delta = $metric =~ m{^last_}
              ? $now - $val
              : $val;
            $reply .= "${group}.${metric}: ${delta}\n";
          }
        }

        reply($client_info, $reply);

        #$backendEvents->once(
        #  'status',
        #  sub {
        #    my $writeCb = shift;
        #    $stream->write("END\n\n");
        #  }
        #);

        # Let each backend contribute its status
        #$backendEvents->emit(
        #  'status',
        #  sub {
        #    my ($err, $name, $stat, $val) = @_;
        #    if ($err) {
        #      warn("Failed to read stats for backend $name: $err");
        #    }
        #    else {
        #      $stat_writer->($name, $stat, $val);
        #    }
        #  }
        #);
    }
    elsif ($cmd eq "counters") {
        my $counters = $self->counters;
        reply($client_info, "$counters\nEND\n\n");
    }
    elsif ($cmd eq "timers") {
        my $timers = $self->timers;
        reply($client_info, "$timers\nEND\n\n");
    }
    elsif ($cmd eq "gauges") {
        my $gauges = $self->gauges;
        reply($client_info, "$gauges\nEND\n\n");
    }
    elsif ($cmd eq "delcounters") {
        my $counters = $self->counters;
        for my $name (@cmdline) {
            delete $counters->{$name};
            reply($client_info, "deleted: $name\n");
        }
        reply($client_info, "END\n\n");
    }
    elsif ($cmd eq "deltimers") {
        my $timers = $self->timers;
        for my $name (@cmdline) {
            delete $timers->{$name};
            reply($client_info, "deleted: $name\n");
        }
        reply($client_info, "END\n\n");
    }
    elsif ($cmd eq "delgauges") {
        my $gauges = $self->gauges;
        for my $name (@cmdline) {
            delete $gauges->{$name};
            reply($client_info, "deleted: $name\n");
        }
        reply($client_info, "END\n\n");
    }
    elsif ($cmd eq "quit") {
        delete_client($client_info);
    }
    else {
        reply($client_info, "ERROR\n");
    }
}

sub counters {
  my ($self) = @_;
  return $self->ctx->{counters};
}

sub timers {
  my ($self) = @_;
  return $self->ctx->{timers};
}

sub gauges {
  my ($self) = @_;
  return $self->ctx->{gauges};
}

sub ctx {
  my ($self) = @_;
  return $self->{server_context};
}

sub stats {
  my ($self) = @_;
  return $self->ctx->{stats};
}

sub trim {
  my $str = shift;
  $str =~ s{^\s*}{};
  $str =~ s{\s*$}{};
  return $str;
}

1;
