# ABSTRACT: Console backend for Net::Statsd::Server

package Net::Statsd::Server::Backend::Console;

use strict;
use warnings;
use JSON::XS ();

use base qw(Net::Statsd::Server::Backend);

sub init {
  my ($self) = @_;

  $self->{statsCache} = {
    counters => {},
    timers => {},
  };

  $self->{json_emitter} = JSON::XS->new->relaxed->utf8->pretty->indent(4);
}

sub flush {
  my ($self, $timestamp, $metrics) = @_;

  print STDERR "Flushing stats at " . localtime($timestamp) . "\n";
  my $sc = $self->{statsCache};
  for my $type (keys %{ $sc }) {
    next unless $metrics->{$type};
    for my $name (keys %{ $metrics->{$type} }) {
      my $value = $metrics->{$type}->{$name};
      $sc->{$type}->{$name} //= 0;
      $sc->{$type}->{$name} += $value;
    }
  }

  my $out = {
    counters      => $sc->{counters},
    timers        => $sc->{timers},
    gauges        => $metrics->{gauges},
    timer_data    => $metrics->{timer_data},
    counter_rates => $metrics->{counter_rates},
    sets          => $metrics->{sets},
    pctThreshold  => $metrics->{pctThreshold},
  };

  print STDERR $self->{json_emitter}->encode($out), "\n";
  return;
}

sub status {
  my ($self) = @_;
  return {
    last_flush     => $self->since($self->{lastFlush}),
    last_exception => $self->since($self->{lastException}),
  };
}

1;
