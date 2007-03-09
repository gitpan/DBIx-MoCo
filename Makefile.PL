use ExtUtils::MakeMaker;
WriteMakefile(
    NAME              => 'DBIx::MoCo',
    VERSION_FROM      => 'lib/DBIx/MoCo.pm',
    PREREQ_PM         => {
        Class::Trigger => 0,
        SQL::Abstract => 0,
        DBI => 0,
        DBD::SQLite => 0,
        List::Util => 0,
        List::MoreUtils => 0,
        Exporter => 0,
        Cache::Memory => 0,
        Test::Class => 0,
        FormValidator::Simple => 0,
        URI => 0,
    },
    ($] >= 5.005 ?
      (ABSTRACT_FROM  => 'lib/DBIx/MoCo.pm',
       AUTHOR         => 'Junya Kondo <jkondo@hatena.com>') : ()),
);
