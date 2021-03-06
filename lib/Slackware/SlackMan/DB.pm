package Slackware::SlackMan::DB;

use strict;
use warnings;

use 5.010;

our ($VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS);

BEGIN {

  require Exporter;

  $VERSION     = 'v1.0.4';
  @ISA         = qw(Exporter);

  @EXPORT_OK   = qw{
    dbh
    db_init
    db_wipe_table
    db_wipe_tables
    db_insert
    db_bulk_insert
    db_compact
    db_meta_get
    db_meta_set
    db_meta_delete
    db_reindex
    $dbh
  };

  %EXPORT_TAGS = (
    all => \@EXPORT_OK,
  );

}

use DBI;
use Sort::Versions;
use Data::Dumper;
use Slackware::SlackMan::Config qw(:all);
use Slackware::SlackMan::Utils  qw(:all);


use constant SLACKMAN_PACKAGES_TABLE => qq/CREATE TABLE IF NOT EXISTS "packages" (
  "id"                INTEGER PRIMARY KEY,
  "repository"        VARCHAR,
  "priority"          INTEGER,
  "excluded"          BOOL,
  "name"              VARCHAR,
  "package"           VARCHAR,
  "version"           VARCHAR,
  "arch"              VARCHAR,
  "build"             INTEGER,
  "tag"               VARCHAR,
  "category"          VARCHAR,
  "summary"           VARCHAR,
  "description"       TEXT,
  "mirror"            VARCHAR,
  "location"          VARCHAR,
  "required"          VARCHAR,
  "conflicts"         VARCHAR,
  "suggests"          VARCHAR,
  "size_compressed"   INTEGER,
  "size_uncompressed" INTEGER,
  "checksum"          VARCHAR)/;

use constant SLACKMAN_HISTORY_TABLE => qq/CREATE TABLE IF NOT EXISTS "history" (
  "id"                INTEGER PRIMARY KEY,
  "name"              VARCHAR,
  "package"           VARCHAR,
  "version"           VARCHAR,
  "arch"              VARCHAR,
  "build"             INTEGER,
  "tag"               VARCHAR,
  "status"            VARCHAR,
  "timestamp"         DATETIME,
  "upgraded"          DATETIME,
  "summary"           VARCHAR,
  "description"       TEXT,
  "size_compressed"   INTEGER,
  "size_uncompressed" INTEGER)/;

use constant SLACKMAN_HISTORY_INDEX => qq/CREATE INDEX IF NOT EXISTS "history_idx" ON "history" (
  "name"              ASC,
  "package"           ASC,
  "arch"              ASC,
  "status"            ASC)/;

use constant SLACKMAN_MANIFEST_TABLE => qq/CREATE TABLE IF NOT EXISTS "manifest" (
  "id"                INTEGER PRIMARY KEY,
  "package_id"        INTEGER,
  "directory"         VARCHAR,
  "file"              VARCHAR)/;

use constant SLACKMAN_CHANGELOGS_TABLE => qq/CREATE TABLE IF NOT EXISTS "changelogs" (
  "id"                INTEGER PRIMARY KEY,
  "repository"        VARCHAR,
  "timestamp"         DATETIME,
  "name"              VARCHAR,
  "package"           VARCHAR,
  "version"           VARCHAR,
  "arch"              VARCHAR,
  "build"             INTEGER,
  "tag"               VARCHAR,
  "category"          VARCHAR,
  "status"            VARCHAR,
  "description"       VARCHAR,
  "security_fix"      BOOL)/;

use constant SLACKMAN_METADATA_TABLE => qq/CREATE TABLE IF NOT EXISTS "metadata" (
  "id"                INTEGER PRIMARY KEY,
  "key"               VARCHAR,
  "value"             VARCHAR)/;

use constant SLACKMAN_SCHEMA => {
  'packages'    => SLACKMAN_PACKAGES_TABLE,
  'metadata'    => SLACKMAN_METADATA_TABLE,
  'changelogs'  => SLACKMAN_CHANGELOGS_TABLE,
  'history'     => SLACKMAN_HISTORY_TABLE,
  'manifest'    => SLACKMAN_MANIFEST_TABLE,
  'history_idx' => SLACKMAN_HISTORY_INDEX,
};

use constant SLACKMAN_TABLES  => ( 'packages', 'metadata', 'changelogs', 'history', 'manifest' );
use constant SLACKMAN_INDEXES => ( 'history_idx' );


our $dbh = dbh();


sub dbh {

  my $dsn = sprintf('dbi:SQLite:dbname=%s/db.sqlite', $slackman_conf->{directory}->{lib});

  my $dbh = DBI->connect($dsn,'', '', {
    PrintError       => 1,
    RaiseError       => 1,
    AutoCommit       => 1,
    FetchHashKeyName => 'NAME_lc',
  }) or die ("Can't open database!");

  $dbh->do('PRAGMA foreign_keys = ON');
  $dbh->do('PRAGMA synchronous  = OFF');
  $dbh->do('PRAGMA journal_mode = MEMORY');
  $dbh->do('PRAGMA temp_store   = MEMORY');
  $dbh->do('PRAGMA user_version = 1');

  $dbh->sqlite_create_function('version_compare', -1, sub {
    my ($old, $new) = @_;
    return versioncmp($old, $new);
  });

  return $dbh;

}

sub db_init {

  foreach (SLACKMAN_TABLES) {
    logger->debug(qq/[DB] Init table "$_"/);
    $dbh->do(SLACKMAN_SCHEMA->{$_});
  }

  foreach (SLACKMAN_INDEXES) {
    logger->debug(qq/[DB] Init index "$_"/);
    $dbh->do(SLACKMAN_SCHEMA->{$_});
  }


}

sub db_wipe_tables {

  foreach (SLACKMAN_TABLES) {
    db_wipe_table($_);
  }

}

sub db_wipe_table {
  logger->debug(qq/[DB] Wipe "$_" table/);
  $dbh->do("DELETE FROM $_");
}

sub db_insert {

  my ($table, $data) = @_;

  my $columns      = join( ', ', map { qq/'$_'/ } keys %$data );
  my $placeholders = join( ', ', map { qq/?/ }    keys %$data );
  my @values       = values %$data;
  my $query        = "INSERT INTO $table($columns) VALUES ($placeholders)";
  my $sth          = $dbh->prepare($query);

  $sth->execute(@values);

}

sub db_compact {
  logger->debug('[DB] Compact database');
  $dbh->do('PRAGMA VACUUM');
}

sub db_reindex {

  foreach (SLACKMAN_TABLES) {
    logger->debug(qq/[DB] Reindex "$_" table/);
    $dbh->do("REINDEX $_");
  }

  foreach (SLACKMAN_INDEXES) {
    logger->debug(qq/[DB] Reindex "$_" index/);
    $dbh->do("REINDEX $_");
  }

}

sub db_bulk_insert {

  my (%params) = @_;

  my $table   = $params{'table'};
  my $columns = $params{'columns'};
  my $values  = $params{'values'};

  my $n_rows  = scalar(@$values);

  logger->debug(qq/[DB] Insert $n_rows rows into "$table" table/);

  my $query = sprintf("INSERT INTO %s(%s) VALUES(%s)",
    $table,
    join(', ', @$columns),
    join(', ', map {qq/?/} @$columns)
  );

  $dbh->begin_work();

  my $sth = $dbh->prepare($query);

  logger->debug(qq/[DB] $query/);

  foreach my $row (@$values) {
    $sth->execute(@$row);
  }

  $dbh->commit();

}

sub db_meta_get {

  my ($key) = @_;
  logger->debug(qq/[DB] Get key "$key" value/);

  return $dbh->selectrow_array(qq/SELECT value FROM metadata WHERE key = ?/, undef, $key);

}

sub db_meta_set {

  my ($key, $value) = @_;
  logger->debug(qq/[DB] Set key "$key" value "$value"/);

  $dbh->do(qq/DELETE FROM metadata WHERE key = ?/, undef, $key);
  $dbh->do(qq/INSERT INTO metadata(key, value) VALUES(?, ?)/, undef, $key, $value);

  return 1;

}

sub db_meta_delete {

  my ($key) = @_;

  logger->debug(qq/[DB] Delete key "$key"/);

  return $dbh->selectrow_array(qq/DELETE FROM metadata WHERE key = ?/, undef, $key);

}

1;
__END__

=head1 NAME

Slackware::SlackMan::DB - SlackMan DB module

=head1 SYNOPSIS

  use Slackware::SlackMan::DB qw(:all);

  db_bulk_insert(
    'table'   => 'foo',
    'columns' => [ 'foo', 'bar', 'baz' ],
    'values'  => [
      [1,2,3],
      [4,5,6]
    ],
  )

=head1 DESCRIPTION

DB module for SlackMan.

=head1 EXPORT

No subs are exported by default.

=head1 SUBROUTINES

=head2 db_bulk_insert

=head2 db_compact

=head2 db_init

=head2 db_insert

=head2 db_meta_get

=head2 db_meta_set

=head2 db_reindex

=head2 db_reindex

=head2 db_wipe_table

=head2 db_wipe_tables

=head2 dbh

=head1 VARIABLES

=head2 $dbh

=head1 AUTHOR

Giuseppe Di Terlizzi, C<< <giuseppe.diterlizzi at gmail.com> >>

=head1 BUGS

Please report any bugs or feature requests to C<giuseppe.diterlizzi at gmail.com>, or through
the web interface at L<https://github.com/LotarProject/slackman/issues>. I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the C<perldoc> command.

  perldoc Slackware::SlackMan::DB

You can also look for information at:

=over 4

=item * GitHub issues (report bugs here)

L<https://github.com/LotarProject/slackman/issues>

=item * SlackMan documentation

L<https://github.com/LotarProject/slackman/wiki>

=back

=head1 LICENSE AND COPYRIGHT

Copyright 2016-2017 Giuseppe Di Terlizzi.

This module is free software, you may distribute it under the same terms
as Perl.

=cut
