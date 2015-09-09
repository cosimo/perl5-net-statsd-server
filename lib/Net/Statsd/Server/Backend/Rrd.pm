# vim: ts=2 sw=4 et

# Flush stats to RRDtool
#
# To enable this backend, include 'rrd' in the backends
# configuration array:
#
#   backends: ['./backends/rrd'] 
#  (if the config file is in the statsd folder)
#
# A sample configuration can be found in exampleRRDConfig.js
#
# This backend supports the following config options:
#
#   path:          root path of the RRD files (default: '/tmp')
#

package Net::Statsd::Server::Backend::Rrd;

use 5.010;
use strict;
use warnings;
use base qw(Net::Statsd::Server::Backend);

our $VERSION = '0.01';
our $CONFIG = { path => '/tmp' };

use Data::Dumper;
use File::Basename;
use File::Path;
use Path::Tiny;
use RRD::Simple;
use RRDs;

my $debug;
my $flushInterval;
my $rrdPath;
my $stats = {};

sub _dir_file {
  my ($key) = @_;
  my @key = split m{\.}, $key;
  my $filename = join('/', @key) . '.rrd';
  my $fullfile = path($CONFIG->{path}, $filename);
  my $basename = File::Basename::basename($filename);
  my $folder = File::Basename::dirname($fullfile);
  #warn "folder=$folder base=$basename full=$fullfile\n";
  return ($folder, $basename, $fullfile);
}

sub write_counter {
  my ($self, @args) = @_;
  return $self->_write_rrd('COUNTER', @args);
}

sub write_gauge {
  my ($self, @args) = @_;
  return $self->_write_rrd('GAUGE', @args);
}

# With RRDs, so we can set our statsd-biased defaults
sub _rrd_create {
  my ($self, $full_filename, $ds_name, $type) = @_;

  if (! $ds_name || ! $type || ! $full_filename) {
    die "Incorrect parameters to _rrd_create()";
  }

  if (-e $full_filename) {
    return;
  }

  my $flush_interval = $CONFIG->{flushInterval} / 1000;
  my %statsd_to_rrd_type = (
    COUNTER => 'ABSOLUTE',
    GAUGE   => 'GAUGE',
    TIMER   => 'GAUGE',    # Sadly, no timer type in RRD
  );

  my $ds_type = $statsd_to_rrd_type{$type};
  my $min_value = $ds_type eq 'ABSOLUTE' ? 0 : 'U';
  my $max_value = 'U';

  my @rrd_spec = (
    '-b' => "-${flush_interval}s",
    '-s' => $flush_interval,
    "DS:${ds_name}:${ds_type}:${flush_interval}:${min_value}:${max_value}",
  );
  my $xff = $CONFIG->{xff} || 0.5;

  my @rra = (
    [ 'AVERAGE', $xff, 10, 1 ],    # 10=seconds, 1=days
    [ 'AVERAGE', $xff, 60, 30 ],
    [ 'AVERAGE', $xff, 300, 2 * 365 ],
  );

  sub steps_from_s {
    my $s = shift;
    return int($s / ($CONFIG->{flushInterval}/1000));
  }

  sub rows_from_days {
    my ($days, $sec_per_step) = @_;
    return 86400 * $days / $sec_per_step;
  }

  for (@rra) {
    my ($cf, $xff, $seconds_per_step, $days) = @{ $_ };
    my $steps = steps_from_s($seconds_per_step);
    my $rows = rows_from_days($days, $seconds_per_step);
    push @rrd_spec, "RRA:${cf}:${xff}:${steps}:${rows}";
  }

  #warn Data::Dumper::Dumper(\@rrd_spec);
  RRDs::create($full_filename, @rrd_spec);
}

sub _write_rrd {
  my ($self, $type, $key, $value, $timestamp) = @_;

  # Statsd server treats timestamp as millisecond values
  $timestamp /= 1000;

  warn " write_rrd: type=$type key=$key value=$value timestamp=$timestamp\n"
    if $debug;

  my ($folder, $basename, $full_filename) = _dir_file($key);

  my $stat_name = $basename;
  $stat_name =~ s{\.rrd$}{};
  $stat_name = substr($stat_name, 0, 20);

  if (! -d $folder) {
    File::Path::mkpath($folder) or
      die "Can't create folder '$folder': $!";
  }

  $self->_rrd_create($full_filename, $stat_name, $type);

  $timestamp ||= time();
  warn "update_rrd: $stat_name = $value (t=$timestamp, $full_filename)\n"
    if $debug;

  my $rrd = RRD::Simple->new(file => $full_filename);
  return $rrd->update($full_filename, $timestamp, $stat_name => $value);
}

sub convert_metrics_to_rrd {
  my ($self, $timestamp, $counters, $timers, $gauges) = @_;

  #say Dumper($counters);
  #say Dumper($timers);
  #say Dumper($gauges);

  if ($counters) {
    for (@{ $counters }) {
      my ($key, $value) = @{ $_ };
      $self->write_counter($key => $value, $timestamp);
    }
  }

  # FIXME Timer_data?
  #if ($timers) {
  #  for (@{ $timers }) {
  #    my ($key, $value) = @{ $_ };
  #    $self->write_gauge($key => $value, $timestamp);
  #  }
  #}

  if ($gauges) {
    for (@{ $gauges }) {
      my ($key, $value) = @{ $_ };
      $self->write_gauge($key => $value, $timestamp);
    }
  }

  return;
}

sub flush {
  my ($self, $timestamp, $metrics) = @_;

  my $num_stats = 0;
  my @counts;
  my @timers;
  my @gauges;

  $timestamp *= 1000;

  for my $key (keys %{ $metrics->{counters} }) {
    my $value = $metrics->{counters}->{$key};
    push @counts, [ $key, $value ];
    $num_stats++;
  }

  # timer_data ?
  for my $key (keys %{ $metrics->{timers} }) {
    my $series = $metrics->{timers}->{$key};
    push @timers, [ $key => $series ];
    $num_stats++;
  }

  for my $key (keys %{ $metrics->{gauges} }) {
    my $value = $metrics->{gauges}->{$key};
    push @gauges, [ $key, $value ];
    $num_stats++;
  }

  if ($num_stats > 0) {
    $self->convert_metrics_to_rrd($timestamp, \@counts, \@timers, \@gauges);
    if ($debug) {
      warn "flushed ${num_stats} stats to RRD\n";
    }
  }

}

sub init {
  my ($self, $startup_time, $config, $events) = @_;

  $debug = $config->{debug};
  my $rrd_config = $config->{rrd} || {};

  my @expected_config_attributes = ('path', 'xff');
  for (@expected_config_attributes) {
    if (exists $rrd_config->{$_} && defined $rrd_config->{$_}) {
      $CONFIG->{$_} = $rrd_config->{$_};
    }
  }

  # Mirror our flushInterval value, so we can create sensible RRDs
  $CONFIG->{flushInterval} = $config->{flushInterval};

  $stats->{last_flush} = $startup_time;
  $stats->{last_exception} = $startup_time;

  return 1;
}

1;
