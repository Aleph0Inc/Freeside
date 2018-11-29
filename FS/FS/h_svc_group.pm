package FS::h_svc_group;

use strict;
use base qw( FS::h_Common FS::svc_group );

sub table { 'h_svc_group' };

=head1 NAME

FS::h_svc_group - Historical installed group service objects

=head1 SYNOPSIS

=head1 DESCRIPTION

An FS::h_svc_group object represents a historical group service.
FS::h_svc_group inherits from FS::h_Common and FS::svc_group.

=head1 BUGS

=head1 SEE ALSO

L<FS::h_Common>, L<FS::svc_group>, L<FS::Record>, schema.html from the base
documentation.

=cut

1;

