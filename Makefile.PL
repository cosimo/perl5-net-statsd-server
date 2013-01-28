use ExtUtils::MakeMaker;

WriteMakefile(
    'AUTHOR'         => 'Cosimo Streppone <cosimo@cpan.org>',
    'NAME'		     => 'Net::Statsd::Server',
    'VERSION_FROM'	 => 'lib/Net/Statsd/Server.pm',
    'PREREQ_PM'		 => {
        'AnyEvent::Handle::UDP' => 0,
        'IO::Socket::INET' => 0,
        'JSON::XS' => 0,
    },
    #'ABSTRACT_FROM'	 => 'lib/Net/Statsd/Server.pm',
    test => { TESTS => "t/*.t t/integration-tests/*.t" },
);
