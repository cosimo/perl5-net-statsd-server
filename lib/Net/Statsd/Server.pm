# ABSTRACT: a Perl port of Etsy's statsd *server*

package Net::Statsd::Server;

# Use statements {{{

use strict;
use warnings;

use JSON::XS ();
use POSIX qw(:errno_h :sys_wait_h);
use Socket;
use Time::HiRes ();

use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Handle::UDP;
use AnyEvent::Log;
use AnyEvent::Socket;

use Net::Statsd::Server::Backend;
use Net::Statsd::Server::Metrics;

# }}}

# Constants and global variables {{{

use constant {
  DEBUG                  => 1,
  DEFAULT_CONFIG_FILE    => 'localConfig.js',
  DEFAULT_FLUSH_INTERVAL => 10000,
  DEFAULT_LOG_LEVEL      => 'info',
};

our $VERSION = '0.01';
our $logger;

# }}}

sub new {
  my ($class, $opt) = @_;
  $opt ||= {};
  $class = ref $class || $class;

  my $startup_time = time();

  # Initialize data structures with defaults for statsd stats
  my $self = {

    startup_time  => $startup_time,
    start_time_hi => [Time::HiRes::gettimeofday],

    server        => undef,
    mgmtServer    => undef,

    config        => undef,
    stats         => {
      messages => {
        "last_msg_seen"  => $startup_time,
        "bad_lines_seen" => 0,
      }
    },
    metrics       => Net::Statsd::Server::Metrics->new(),

    debugInt      => undef,
    flushInterval => undef,
    keyFlushInt   => undef,

    backends      => [],
    logger        => $logger,
  };

  $self->{$_} = $opt->{$_}
    for keys %{ $opt };

  bless $self, $class;
}

# Flatten JSON booleans to avoid calls to JSON::XS::bool
# in the performance-critical code paths
sub _flatten_bools {
  my ($self, $conf_hash) = @_;
  for (qw(dumpMessages debug)) {
    $conf_hash->{$_} = !! $conf_hash->{$_};
  }
  return $conf_hash;
}

sub _start_time_hi {
  return $_[0]->{start_time_hi};
}

sub config_defaults {
  return {
    "debug" => 0,
    "debugInterval" => 10000,                  # ms
    "graphitePort"  => 2003,
    "port"          => 8125,
    "address"       => "0.0.0.0",
    "mgmt_port"     => 8126,
    "mgmt_address"  => "0.0.0.0",
    "flushInterval" => DEFAULT_FLUSH_INTERVAL, # ms
    #"keyFlush" => {
    #  "interval" => 10,                        # s
    #  "percent"  => 100,
    #  "log"      => "",            # FIXME What's this?
    #},
    #"log" => {
    #},
    "percentThreshold" => 90,
    "dumpMessages" => 0,
    "backends" => [
      "graphite"
    ],
  };
}

sub config {
  my ($self, $config_file) = @_;

  if (exists $self->{config} && defined $self->{config}) {
    return $self->{config};
  }

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

  $conf_hash = $self->_flatten_bools($conf_hash);

  # Poor man's Hash::Merge
  for (keys %{ $defaults }) {
    if (! exists $conf_hash->{$_}) {
      $conf_hash->{$_} = $defaults->{$_};
    }
  }

  return $self->{config} = $conf_hash;
}

sub counters {
  $_[0]->{metrics}->counters;
}

sub default_config_file {
  DEFAULT_CONFIG_FILE;
}

sub flush_metrics {
  my ($self) = @_;
  my $flush_start_time = time;
  $logger->(notice => "flushing metrics");
  my $flush_interval = $self->config->{flushInterval};
  my $metrics = $self->metrics->process($flush_interval);
  $self->foreach_backend(sub {
    $_[0]->flush($flush_start_time, $metrics);
  });
  return;
}

sub gauges {
  return $_[0]->{metrics}->{gauges};
}

# This is the performance-critical section of Net::Statsd::Server.
# Everything below has been optimised for performance rather than
# legibility or transparency. Be careful.

sub handle_client_packet {
  my ($self, $request) = @_;

  my $config   = $self->{config};
  my $metrics  = $self->{metrics};
  my $counters = $metrics->{counters};
  my $stats    = $self->{stats};

  $counters->{"statsd.packets_received"}++;

  # TODO backendEvents.emit('packet', msg, rinfo);

  my @metrics = split("\n", $request);

  my $dump_messages = $config->{dumpMessages};
  my $must_count_keys = exists $config->{keyFlushInterval}
    && $config->{keyFlushInterval} > 0;

  for my $m (@metrics) {

    $logger->(debug => $m) if $dump_messages;

    my @bits = split(":", $m);
    my $key = shift @bits;

    $key =~ y{/ }{_-}s;
    $key =~ y{a-zA-Z0-9\-\.}{}cd;

    # Not very clear here. Etsy's code was doing this differently
    if ($must_count_keys) {
      my $key_counter = $metrics->{keyCounter};
      $key_counter->{$key}++;
    }

    push @bits, "1" if 0 == @bits;

    for my $i (0..$#bits) {

      my $sample_rate = 1;
      my @fields = split(/\|/, $bits[$i]);

      if (! defined $fields[1] || $fields[1] eq "") {
        $logger->("Bad line: $bits[$i] in msg \"$m\"");
        $counters->{"statsd.bad_lines_seen"}++;
        $stats->{"messages"}->{"bad_lines_seen"}++;
        next;
      }

      my $value = $fields[0] || 0;
      my $unit = $fields[1];
      for ($unit) {
        s{^\s*}{};
        s{\s*$}{};
      }

      # Timers
      if ($unit eq "ms") {
        my $timers = $metrics->{timers};
        $timers->{$key} ||= [];
        push @{ $timers->{$key} }, $value;
      }

      # Gauges
      elsif ($unit eq "g") {
        my $gauges = $metrics->{gauges};
        $gauges->{$key} = $value;
      }

      # Sets
      elsif ($unit eq "s") {
        # Treat set as a normal hash with undef keys
        # to minimize memory consumption *and* insertion speed
        my $sets = $metrics->{sets};
        $sets->{$key} ||= {};
        $sets->{$key}->{$value} = undef;
      }

      # Counters
      else {
        if (defined $fields[2]) {
          if ($fields[2] =~ m{^\@([\d\.]+)}) {
            $sample_rate = $1 + 0;
          }
          else {
            $logger->("Bad line: $bits[$i] in msg \"$m\"; has invalid sample rate");
            $counters->{"statsd.bad_lines_seen"}++;
            $stats->{"messages"}->{"bad_lines_seen"}++;
            next;
          }
        }
        $counters->{$key} ||= 0;
        $value ||= 1;
        $value /= $sample_rate;
        $counters->{$key} += $value;
      }
    }
  } 

  $stats->{"messages"}->{"last_msg_seen"} = time();
}

sub handle_manager_command {
  my ($self, $handle, $request) = @_;
  my @cmdline = split(" ", trim($request));
  my $cmd = shift @cmdline;
  my $reply;

  #$logger->(notice => "Mgmt command is '$cmd' (req=$request)");

  if ($cmd eq "help") {
      $reply = (
        "Commands: stats, counters, timers, gauges, delcounters, deltimers, delgauges, quit\015\012\015\012"
      );
  }
  elsif ($cmd eq "stats") {
      my $now = time;
      my $uptime = $now - $self->{startup_time};
      $reply = "uptime: $uptime\n";

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

      $self->foreach_backend(sub {
        my $backend_status = $_[0]->status;
        if ($backend_status && ref $backend_status eq "HASH") {
          for (keys %{ $backend_status }) {
            $reply .= sprintf("%s.%s: %s\n",
              lc($_[0]->name),
              $_ => $backend_status->{$_}
            );
          }
        }
      });

      $reply .= "END\n\n";
  }
  elsif ($cmd eq "counters") {
      my $counters = $self->counters;
      $reply = ("$counters\nEND\n\n");
  }
  elsif ($cmd eq "timers") {
      my $timers = $self->timers;
      $reply = ("$timers\nEND\n\n");
  }
  elsif ($cmd eq "gauges") {
      my $gauges = $self->gauges;
      $reply = ("$gauges\nEND\n\n");
  }
  elsif ($cmd eq "delcounters") {
      my $counters = $self->counters;
      for my $name (@cmdline) {
          delete $counters->{$name};
          $reply .= "deleted: $name\n";
      }
      $reply .= "END\n\n";
  }
  elsif ($cmd eq "deltimers") {
      my $timers = $self->timers;
      for my $name (@cmdline) {
          delete $timers->{$name};
          $reply .= "deleted: $name\n";
      }
      $reply .= "END\n\n";
  }
  elsif ($cmd eq "delgauges") {
      my $gauges = $self->gauges;
      for my $name (@cmdline) {
          delete $gauges->{$name};
          $reply .= "deleted: $name\n";
      }
      $reply .= "END\n\n";
  }
  elsif ($cmd eq "quit") {
      undef $reply;
      $handle->destroy();
  }
  else {
      $reply = "ERROR\n";
  }
  return $reply;
}

sub handle_manager_connection {
  my ($self, $handle, $line) = @_;
  #$logger->(notice => "Received mgmt command [$line]");
  if (my $reply = $self->handle_manager_command($handle, $line)) {
    #$logger->(notice => "Sending mgmt reply [$reply]");
    $handle->push_write($reply);
    # Accept a new command on the same connection
    $handle->push_read(line => sub {
      handle_manager_connection($self, @_)
    });
  }
  else {
    #$logger->(notice => "Shutting down socket");
    $handle->push_write("\n");
    $handle->destroy;
  }
}

sub init_backends {
  my ($self) = @_;
  my $backends = $self->config->{backends};
  if (! $backends or ref $backends ne 'ARRAY') {
    die "At least one backend is needed in your configuration";
  }
  for my $backend (@{ $backends }) {
    my $pkg = $backend;
    if ($backend =~ m{^ (\w+) $}x) {
      $pkg = "Net::Statsd::Server::Backend::${pkg}";
    }
    my $mod = $pkg;
    $mod =~ s{::}{/}g;
    $mod .= ".pm";
    eval {
      require $mod ; 1
    } or do {
      $logger->("Backend ${backend} failed to load: $@");
      next;
    };
    $self->register_backend($pkg);
  }
}

sub init_logger {
  my ($self, $config) = @_;

  $config ||= {};

  my $backend = $config->{backend} || 'stdout';
  my $level = lc($config->{level} || 'LOG_INFO');
  $level =~ s{^log_}{};

  if ($backend eq 'stdout') {
    $AnyEvent::Log::FILTER->level($level);
  }
  elsif ($backend eq 'syslog') {
    # Syslog logging works commenting out the FILTER->level line
    $AnyEvent::Log::COLLECT->attach(
      AnyEvent::Log::Ctx->new(
        level         => $level,
        log_to_syslog => "user",
      )
    );
  }
  $logger ||= sub { AE::log(shift(@_), shift(@_)) };
}

sub logger {
  return $logger;
}

sub metrics {
  $_[0]->{metrics};
}

sub register_backend {
  my ($self, $backend) = @_;
  $self->{backends} ||= [];
  my $backend_instance = $backend->new(
    $self->_start_time_hi, $self->config,
  );
  $logger->(notice => "Initializing $backend backend");
  push @{ $self->{backends} }, $backend_instance;
}

sub foreach_backend {
  my ($self, $callback) = @_;
  my $backends = $self->{backends} || [];
  for my $obj (@{ $backends }) {
    eval {
      $callback->($obj); 1;
    } or do {
      $logger->(error => "Failed callback on $obj backend: $@");
    };
  }
}

sub reload_config {
  my ($self) = @_;
  delete $self->{config};
  $logger->(warn => "Received SIGHUP: reloading configuration");
  return $self->{config} = $self->config();
}

sub setup_timer {
  my ($self) = @_;

  my $flush_interval = $self->config->{flushInterval}
    || DEFAULT_FLUSH_INTERVAL;

  $flush_interval = $flush_interval / 1000;
  $logger->(notice => "metrics flush will happen every ${flush_interval}s");

  my $flush_t = AE::timer $flush_interval, $flush_interval, sub {
    $self->flush_metrics
  };

  return $flush_t;
}

sub start_server {
  my ($self, $config) = @_;

  if (! defined $config) {
    $config = $self->config();
  }

  $self->init_logger($config->{log});

  my $host = $config->{address} || '0.0.0.0';
  my $port = $config->{port}    || 8125;

  my $mgmt_host = $config->{mgmt_address} || '0.0.0.0';
  my $mgmt_port = $config->{mgmt_port}    || 8126;

  $self->init_backends();

  # Statsd clients interface (UDP)
  $self->{server} = AnyEvent::Handle::UDP->new(
    bind => [$host, $port],
    on_recv => sub {
      my ($data, $ae_handle, $client_addr) = @_;
      #$logger->(debug => "Got data=$data self=$self");
      my $reply = $self->handle_client_packet($data);
      $ae_handle->push_send($reply, $client_addr);
    },
  );

  # Management interface (TCP, for 'stats' command, etc...)
  $self->{mgmtServer} = AnyEvent::Socket::tcp_server $mgmt_host, $mgmt_port, sub {
    my ($fh, $host, $port) = @_
      or die "Unable to connect: $!";

    my $handle; $handle = AnyEvent::Handle->new(
      fh => $fh,
      on_error => sub {
        AE::log error => $_[2],
        $_[0]->destroy;
      },
      on_eof => sub {
        $handle->destroy;
        AE::log info => "Done.",
      },
    );

    $handle->push_read(line => sub {
      handle_manager_connection($self, @_)
    });
  };

  $logger->(notice => "statsd server started on ${host}:${port} (v${VERSION})"); 
  $logger->(notice => "manager interface started on ${mgmt_host}:${mgmt_port}");

  my $ti = $self->setup_timer;

  # This will block waiting for
  # incoming connections (TCP) or packets (UDP)
  my $cv = AE::cv;
  $cv->recv();
}

sub stats {
  $_[0]->{stats};
}

sub timers {
  $_[0]->{metrics}->{timers};
}

sub trim {
  $_[0] =~ s{^\s*}{};
  $_[0] =~ s{\s*$}{};
  return $_[0];
}

sub sets {
  $_[0]->{metrics}->sets;
}

1;
