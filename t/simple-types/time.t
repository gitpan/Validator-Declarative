#!/usr/bin/env perl

use strict;
use warnings;
use lib './t/lib';

use Test::Validator::Declarative qw/ check_type_validation /;

my $hour   = [ 0 .. 23 ];
my $minute = [ 0 .. 59 ];
my $second = [ 0 .. 59 ];
check_type_validation(
    type => 'time',
    good => [
        map {
            my $s = $_;
            map {
                my $m = $_;
                map {
                    my $h = $_;
                    sprintf( '%02d:%02d:%02d', $h, $m, $s );
                   } @$hour
               } @$minute
        } @$second
    ],
    bad => [
        '70:00:00',
        '31:01:01',
        '21:81:01',
        '21:31:61',
        '',               # empty string
        'some string',    # arbitrary string
        v5.10.2,          # v-string
        sub { return 'TRUE' },    # coderef
        0, '1.00', '0.1', '-1.00', '-0.1', -1, -10, -123.456e10,
    ]
);

