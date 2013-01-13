#
# Flush stats to graphite (http://graphite.wikidot.com/).
#
# To enable this backend, include 'graphite' in the backends
# configuration array:
#
#   backends: ['graphite']
#
# This backend supports the following config options:
#
#   graphiteHost: Hostname of graphite server.
#   graphitePort: Port to contact graphite server at.
#

package Net::Statsd::Server::Backend::Graphite;

use 5.010;
use strict;
use warnings;
use base qw(Net::Statsd::Server::Backend);
use AnyEvent::Log;
use IO::Socket::INET ();
use Time::HiRes      ();

sub init {
  my ($self, $startup_time, $config) = @_;

  for (qw(debug graphiteHost graphitePort)) {
    $self->{$_} = $config->{$_};
  }

  $config->{graphite} ||= {};

  my $globalPrefix    = $config->{graphite}->{globalPrefix}    // "stats";
  my $prefixCounter   = $config->{graphite}->{prefixCounter}   // "counters";
  my $prefixTimer     = $config->{graphite}->{prefixTimer}     // "timers";
  my $prefixGauge     = $config->{graphite}->{prefixGauge}     // "gauges";
  my $prefixSet       = $config->{graphite}->{prefixSet}       // "sets";
  my $legacyNamespace = $config->{graphite}->{legacyNamespace} // 1;

  my $globalNamespace  = ['stats'];
  my $counterNamespace = ['stats'];
  my $timerNamespace   = ['stats', 'timers'];
  my $gaugesNamespace  = ['stats', 'gauges'];
  my $setsNamespace    = ['stats', 'sets'];

  if (! $legacyNamespace) {

    if ($globalPrefix ne "") {
      push @{ $globalNamespace },  $globalPrefix;
      push @{ $counterNamespace }, $globalPrefix;
      push @{ $timerNamespace },   $globalPrefix;
      push @{ $gaugesNamespace },  $globalPrefix;
      push @{ $setsNamespace },    $globalPrefix;
    }

    if ($prefixCounter ne "") {
      push @{ $counterNamespace }, $prefixCounter;
    }

    if ($prefixTimer ne "") {
      push @{ $timerNamespace }, $prefixTimer;
    }

    if ($prefixGauge ne "") {
      push @{ $gaugesNamespace }, $prefixGauge;
    }

    if ($prefixSet ne "") {
      push @{ $setsNamespace }, $prefixSet;
    }

  }

  $self->{globalPrefix}     = $globalPrefix;
  $self->{prefixCounter}    = $prefixCounter;
  $self->{prefixTimer}      = $prefixTimer;
  $self->{prefixGauge}      = $prefixGauge;
  $self->{prefixSet}        = $prefixSet;
  $self->{legacyNamespace}  = $legacyNamespace;

  $self->{globalNamespace}  = $globalNamespace;
  $self->{counterNamespace} = $counterNamespace;
  $self->{timerNamespace}   = $timerNamespace;
  $self->{gaugesNamespace}  = $gaugesNamespace;
  $self->{setsNamespace}    = $setsNamespace;

  #$self->{graphiteStats}->{last_flush} =
  #$self->{graphiteStats}->{last_exception} = $startup_time;

  $self->{flushInterval} = $config->{flushInterval};
}

sub post_stats {
  my ($self, $stat_string) = @_;

  my $last_flush = $self->{lastFlush} || 0;
  my $last_exception = $self->{lastException} || 0;

  return if ! $self->{graphiteHost};

  eval {
    my $host = $self->{graphiteHost};
    my $port = $self->{graphitePort};
    my $graphite = IO::Socket::INET->new(
      PeerHost => $host,
      PeerPort => $port,
    ) or die "Can't connect to Graphite on ${host}:${port}: $!";

    my $ts = time();

    # TODO ??? Verify
    my @namespace = @{ $self->{globalNamespace} };
    push @namespace, "statsd";
    my $namespace = join(".", @namespace);

    $stat_string .= sprintf("%s.graphiteStats.last_exception %d %d\n",
        $namespace, $last_exception, $ts);
    $stat_string .= sprintf("%s.graphiteStats.last_flush %d %d\n",
        $namespace, $last_flush, $ts);

    $graphite->send($stat_string);
    $graphite->close();

    $self->{lastFlush} = [Time::HiRes::gettimeofday];
  }
  or do {
    if ($self->{debug}) {
      # TODO use logger!
      warn("Exception while posting stats to Graphite: $@");
    }
    $self->{lastException} = [Time::HiRes::gettimeofday];
  };

}

sub flush {
  my ($self, $timestamp, $metrics) = @_;

  my $ts_suffix = " $timestamp\n";
  my $startTime = [Time::HiRes::gettimeofday];
  my $statString = "";
  my $numStats = 0;
  my $timer_data_key;

  my $counters = $metrics->{counters};
  my $gauges = $metrics->{gauges};
  my $timers = $metrics->{timers};
  my $sets = $metrics->{sets};
  my $counter_rates = $metrics->{counter_rates};
  my $timer_data = $metrics->{timer_data};
  my $statsd_metrics = $metrics->{statsd_metrics};

  for my $key (keys %{ $counters }) {

    my @namespace = (@{ $self->{counterNamespace} }, $key);
    my $namespace = join(".", @namespace);

    my $value = $counters->{$key};
    my $valuePerSecond = $counter_rates->{$key}; # pre-calculated "per second" rate

    if ($self->{legacyNamespace}) {
      $statString .= "$namespace $valuePerSecond $ts_suffix";
      $statString .= "stats_counts.$key $value $ts_suffix";
    } else {
      $statString .= "$namespace.rate $valuePerSecond $ts_suffix";
      $statString .= "$namespace.count $value $ts_suffix";
    }
    $numStats++;
  }

  for my $key (keys %{ $timer_data }) {
    if ($timer_data->{$key} && keys %{ $timer_data->{$key} } > 0) {
      for my $timer_data_key (keys %{ $timer_data->{$key} }) {
        my @namespace = (@{ $self->{timerNamespace} }, $key);
        my $the_key = join(".", @namespace);
        $statString .= "$the_key.$timer_data_key "
          . $timer_data->{$key}->{$timer_data_key}
          . $ts_suffix;
      }
      $numStats++;
    }
  }

  for my $key (keys %{ $gauges }) {
    my @namespace = (@{ $self->{gaugesNamespace} }, $key);
    $statString .= join(".", @namespace) . " " . $gauges->{$key} . $ts_suffix;
    $numStats++;
  }

  for my $key (keys %{ $sets }) {
    my @namespace = (@{ $self->{setsNamespace} }, $key);
    my $namespace = join(".", @namespace);
    my $set_card = scalar keys %{ $sets->{$key} };
    $statString .= "$namespace.count $set_card $ts_suffix";
    $numStats++;
  }

  my @namespace = (@{ $self->{globalNamespace} }, "statsd");

  # Convert Time::HiRes format (µs) to ms
  my $calcTime = sprintf "%.6f", 1000 * Time::HiRes::tv_interval($startTime);

  if ($self->{legacyNamespace}) {
    $statString .= "statsd.numStats $numStats $ts_suffix";
    $statString .= "stats.statsd.graphiteStats.calculationtime $calcTime $ts_suffix";
    for my $key (keys %{ $statsd_metrics }) {
      $statString .= "stats.statsd.$key $statsd_metrics->{$key} $ts_suffix";
    }
  }
  else {
    my $namespace = join(".", @namespace);
    $statString .= "$namespace.numStats $numStats $ts_suffix";
    $statString .= "$namespace.graphiteStats.calculationtime $calcTime $ts_suffix";
    for my $key (keys %{ $statsd_metrics }) {
      my $value = $statsd_metrics->{$key};
      $statString .= "$namespace.$key $value $ts_suffix";
    }
  }
  $self->post_stats($statString);
}

sub status {
  my ($self) = @_;
  my $stats = $self->{graphiteStats};
  return {
    last_flush => $self->since($self->{lastFlush}),
    last_exception => $self->since($self->{lastException}),
  };
}

1;
