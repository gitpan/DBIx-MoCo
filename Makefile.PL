use ExtUtils::MakeMaker;
WriteMakefile(
    NAME              => 'DBIx::MoCo',
    VERSION_FROM      => 'lib/DBIx/MoCo.pm',
    PREREQ_PM         => {
        Class::Trigger => '',
        SQL::Abstract => '',
        DBI => '',
        DBD::SQLite => '',
        List::Util => '',
        List::MoreUtils => '',
        Exporter => '',
        Cache::Memory => '',
    },
    ($] >= 5.005 ?
      (ABSTRACT_FROM  => 'lib/DBIx/MoCo.pm',
       AUTHOR         => 'Junya Kondo <jkondo@hatena.com>') : ()),
);
