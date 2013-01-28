=head1 NAME

t/graphite.t - Net::Statsd::Server test suite

=head1 DESCRIPTION

Test the integration of statsd with Graphite.

=cut

use strict;
use warnings;
use Data::Dumper;
use Test::More;

use Net::Statsd::Server::Metrics;
use Net::Statsd::Server::Backend::Graphite;

plan tests => 2;

# Helper functions {{{

sub setup {
  my $config = shift || {};
  my $startup_time = time();
  my $graphite = Net::Statsd::Server::Backend::Graphite->new(
    $startup_time, $config
  );
  return $graphite;
}

sub process_metrics {
  my $metrics = shift;
  my $m = Net::Statsd::Server::Metrics->new();
  if (exists $metrics->{counters}) {
    for (keys %{ $metrics->{counters} }) {
      $m->{counters}->{$_} = $metrics->{counters}->{$_};
    }
  }
  my $proc = $m->process(1000);
  return $proc;
}

sub flush_stats {
  my $test_case = shift;
  my $time = time();
  my $g = setup({
    graphite => { legacyNamespace => 0 }
  });
  my $metrics = process_metrics($test_case);
  my $stats = $g->flush_stats($time, $metrics);
  #diag($g->stats_to_string($stats));
  return $stats;
}

# }}}

# Test cases {{{

sub connect_and_get_empty_metrics {
  my $stats = flush_stats({});
  my $numStats;
  for (@{ $stats }) {
    if ($_->{stat} eq "stats.statsd.numStats") {
      $numStats = $_;
      last;
    }
  }
  ok($numStats,
    'statsd.numStats metric is present');
  is($numStats->{value}, 2,
    'Two statsd metrics should be output');
}

# }}}

connect_and_get_empty_metrics();

=cut

  send_malformed_post: function (test) {
    test.expect(3);

    var testvalue = 1;
    var me = this;
    this.acceptor.once('connection',function(c){
      statsd_send('a_bad_test_value|z',me.sock,'127.0.0.1',8125,function(){
          collect_for(me.acceptor,me.myflush*2,function(strings){
            test.ok(strings.length > 0,'should receive some data');
            var hashes = _.map(strings, function(x) {
              var chunks = x.split(' ');
              var data = {};
              data[chunks[0]] = chunks[1];
              return data;
            });
            var numstat_test = function(post){
              var mykey = 'stats.statsd.numStats';
              return _.include(_.keys(post),mykey) && (post[mykey] == 2);
            };
            test.ok(_.any(hashes,numstat_test), 'statsd.numStats should be 0');

            var bad_lines_seen_value_test = function(post){
              var mykey = 'stats.counters.statsd.bad_lines_seen.count';
              return _.include(_.keys(post),mykey) && (post[mykey] == testvalue);
            };
            test.ok(_.any(hashes,bad_lines_seen_value_test), 'stats.counters.statsd.bad_lines_seen.count should be ' + testvalue);

            test.done();
          });
      });
    });
  },

  timers_are_valid: function (test) {
    test.expect(3);

    var testvalue = 100;
    var me = this;
    this.acceptor.once('connection',function(c){
      statsd_send('a_test_value:' + testvalue + '|ms',me.sock,'127.0.0.1',8125,function(){
          collect_for(me.acceptor,me.myflush*2,function(strings){
            test.ok(strings.length > 0,'should receive some data');
            var hashes = _.map(strings, function(x) {
              var chunks = x.split(' ');
              var data = {};
              data[chunks[0]] = chunks[1];
              return data;
            });
            var numstat_test = function(post){
              var mykey = 'stats.statsd.numStats';
              return _.include(_.keys(post),mykey) && (post[mykey] == 3);
            };
            test.ok(_.any(hashes,numstat_test), 'stats.statsd.numStats should be 1');

            var testtimervalue_test = function(post){
              var mykey = 'stats.timers.a_test_value.mean_90';
              return _.include(_.keys(post),mykey) && (post[mykey] == testvalue);
            };
            test.ok(_.any(hashes,testtimervalue_test), 'stats.timers.a_test_value.mean should be ' + testvalue);

            test.done();
          });
      });
    });
  },

  counts_are_valid: function (test) {
    test.expect(4);

    var testvalue = 100;
    var me = this;
    this.acceptor.once('connection',function(c){
      statsd_send('a_test_value:' + testvalue + '|c',me.sock,'127.0.0.1',8125,function(){
          collect_for(me.acceptor,me.myflush*2,function(strings){
            test.ok(strings.length > 0,'should receive some data');
            var hashes = _.map(strings, function(x) {
              var chunks = x.split(' ');
              var data = {};
              data[chunks[0]] = chunks[1];
              return data;
            });
            var numstat_test = function(post){
              var mykey = 'stats.statsd.numStats';
              return _.include(_.keys(post),mykey) && (post[mykey] == 3);
            };
            test.ok(_.any(hashes,numstat_test), 'statsd.numStats should be 3');

            var testavgvalue_test = function(post){
              var mykey = 'stats.counters.a_test_value.rate';
              return _.include(_.keys(post),mykey) && (post[mykey] == (testvalue/(me.myflush / 1000)));
            };
            test.ok(_.any(hashes,testavgvalue_test), 'a_test_value.rate should be ' + (testvalue/(me.myflush / 1000)));

            var testcountvalue_test = function(post){
              var mykey = 'stats.counters.a_test_value.count';
              return _.include(_.keys(post),mykey) && (post[mykey] == testvalue);
            };
            test.ok(_.any(hashes,testcountvalue_test), 'a_test_value.count should be ' + testvalue);

            test.done();
          });
      });
    });
  }
}
