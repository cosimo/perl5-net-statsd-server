# ABSTRACT: Provides metrics abstraction to a running statsd server

package Net::Statsd::Server::Metrics;

use 5.010;
use strict;
use Carp        ();
use Time::HiRes ();

sub new {
  my ($class, $config) = @_;
  $class = ref $class || $class;
  my $g_pref = $config->{prefixStats};
  if (! $g_pref) {
    Carp::croak("prefixStats is empty or invalid! (Metrics.new)");
  }

  my $self = {
    keyCounter => {},
    counters => {
      "${g_pref}.packets_received" => 0,
      "${g_pref}.bad_lines_seen"   => 0,
    },
    timers => {},
    gauges => {},
    sets => {},
    counter_rates => {},
    timer_data => {},
    pctThreshold => [ 90 ],
  };
  bless $self, $class;
}

sub process {
  my ($self, $flush_interval) = @_;

  my $starttime = [Time::HiRes::gettimeofday];
  my $key;

  my $metrics = $self->as_hash;
  my $counters = $metrics->{counters};
  my $timers = $metrics->{timers};
  my $pctThreshold = $metrics->{pctThreshold};

  # Meta metrics added by statsd
  my $counter_rates = {};
  my $timer_data = {};
  my $statsd_metrics = {};

  # Calculate "per second" rate
  $flush_interval /= 1000;

  for my $key (keys %{ $counters }) {
    my $value = $counters->{$key};
    $counter_rates->{$key} = $value / $flush_interval;
  }

  # Calculate all requested
  # percentile values (90%, 95%, ...)
  for my $key (keys %{ $timers }) {

    next unless @{ $timers->{$key} } > 0;

    my $current_timer_data = {};

    # Sort timer samples by value
    my @values = @{ $timers->{$key} };
    @values = sort { $a <=> $b } @values;

    my $count = @values;
    my $min = $values[0];
    my $max = $values[$#values];

    # We don't want to iterate at all if there's just 1 value
    my $cumulativeValues = [ $min ];
    for (my $i = 1; $i < $count; $i++) {
      my $cmlVal = $values[$i] + $cumulativeValues->[$i - 1];
      push @{ $cumulativeValues }, $values[$i] + $cumulativeValues->[$i - 1];
    }

    my $sum = my $mean = $min;
    my $maxAtThreshold = $max;

    for my $pct (@{ $pctThreshold }) {

      if ($count > 1) {
        # Pay attention to the rounding: should behave the same
        # as etsy's statsd, that's using a Math.round(x).
        # int(x + 0.5) does this.
        my $numInThreshold = int(($pct / 100 * $count) + 0.5);
        $maxAtThreshold = $values[$numInThreshold - 1];
        $sum = $cumulativeValues->[$numInThreshold - 1];
        $mean = $sum / $numInThreshold;
      }

      my $clean_pct = "" . $pct;
      $clean_pct =~ s{\.}{_}g;

      $current_timer_data->{"mean_${clean_pct}"}  = $mean;
      $current_timer_data->{"upper_${clean_pct}"} = $maxAtThreshold;
      $current_timer_data->{"sum_${clean_pct}"}   = $sum;
    }

    $sum = $cumulativeValues->[$count - 1];
    $mean = $sum / $count;

    # Calculate standard deviation
    my $sumOfDiffs = 0;
    for (0 .. $count - 1) {
       $sumOfDiffs += ($values[$_] - $mean) ** 2;
    }
    my $stddev = sqrt($sumOfDiffs / $count);

    $current_timer_data->{std} = $stddev;
    $current_timer_data->{upper} = $max;
    $current_timer_data->{lower} = $min;
    $current_timer_data->{count} = $count;
    $current_timer_data->{sum} = $sum;
    $current_timer_data->{mean} = $mean;

    $timer_data->{$key} = $current_timer_data;
  }

  # This is originally ms in statsd
  $statsd_metrics->{processing_time} = Time::HiRes::tv_interval($starttime) * 1000;

  # Add processed metrics to the metrics_hash
  $metrics->{counter_rates}  = $counter_rates;
  $metrics->{timer_data}     = $timer_data;
  $metrics->{statsd_metrics} = $statsd_metrics;

  return $metrics;
}

sub as_hash {
  my $self = $_[0];

  my %metrics = (
    counters => $self->{counters},
    timers   => $self->{timers},
    gauges   => $self->{gauges},
    pctThreshold => $self->{pctThreshold},
  );

  return \%metrics;
}

1;
