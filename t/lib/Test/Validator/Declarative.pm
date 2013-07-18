#!/usr/bin/env perl

use strict;
use warnings;

package Test::Validator::Declarative;

use Exporter;
use Test::More;
use Test::Exception;
use Data::Dumper;
use Validator::Declarative;

our @ISA       = qw/ Exporter /;
our @EXPORT_OK = qw/ check_type_validation /;

sub check_type_validation {
    my %param = @_;

    # for lives_ok + is_deeply + throws_ok + message for each error
    plan tests => 4 + 1 + scalar( @{ $param{bad} } );

    my ( $type, $values, @result, $type_name, $stringified_type );

    $type = $param{type};

    ($type_name) =    # there should be exactly one k/v pair
          ref($type) eq 'HASH'  ? keys(%$type)
        : ref($type) eq 'ARRAY' ? $type->[0]
        :                         $type;

    $stringified_type = struct_to_str($type);

    #
    # check type validation pass
    #
    $values = $param{good};
    lives_ok {
        @result = Validator::Declarative::validate( [undef] => [ "param_${type_name}_0" => [ 'optional', $type ] ] );
    }
    "type 'optional,$stringified_type' lives on undef";
    is_deeply( \@result, [undef], "type 'optional,$stringified_type' returns expected result" );

    lives_ok {
        @result = Validator::Declarative::validate(
            $values => [ map { sprintf( "param_${type_name}_%02d", $_ ) => $type, } 1 .. scalar @$values ] );
    }
    "type $stringified_type lives on correct parameters";
    is_deeply( \@result, $values, "type $stringified_type returns expected result" );

    #
    # check type validation fail
    #
    $values = $param{bad};
    throws_ok {
        Validator::Declarative::validate(
            $values => [ map { sprintf( "param_${type_name}_%02d", $_ ) => $type, } 1 .. scalar @$values ] );
    }
    'Error::Simple', "type $stringified_type throws on incorrect parameters";

    my $error_text = "$@";
    for ( 1 .. scalar @$values ) {
        my $param = sprintf( "param_${type_name}_%02d", $_ );
        my $regexp = sprintf( "%s: .* does not satisfy %s", $param, uc($type_name) );
        like $error_text, qr/^$regexp/m, "message about $param";
    }

}

sub struct_to_str {
    my ( $struct, $maxdepth, $use_deparse ) = @_;

    $maxdepth    ||= 3;
    $use_deparse ||= 0;

    local $Data::Dumper::Deparse   = $use_deparse;
    local $Data::Dumper::Indent    = 0;
    local $Data::Dumper::Maxdepth  = $maxdepth;
    local $Data::Dumper::Quotekeys = 1;
    local $Data::Dumper::Sortkeys  = 1;
    local $Data::Dumper::Terse     = 1;
    local $Data::Dumper::Useqq     = 0;

    return Data::Dumper::Dumper($struct);
}

1;

