package PDL::Gnuplot;

use strict;
use warnings;
use PDL;
use IO::Handle;
use List::Util;
use List::MoreUtils qw(part);
use feature qw(say);
our $VERSION = 1.00;

$PDL::use_commas = 1;

use base 'Exporter';
our @EXPORT_OK = qw(plot);


sub new
{
  my $classname = shift;

  my %plotoptions = ();
  if(@_)
  {
    if(ref $_[0])
    { %plotoptions = %{$_[0]}; }
    else
    { %plotoptions = @_; }
  }

  my $pipe = startGnuplot( $plotoptions{dump} ) or barf "Couldn't start gnuplot backend";
  say $pipe parseOptions(\%plotoptions);

  my $this = {pipe    => $pipe,
              options => \%plotoptions};
  bless($this, $classname);

  return $this;


  sub startGnuplot
  {
    # if we're simply dumping the gnuplot commands to stdout, simply return a handle to STDOUT
    my $dump = shift;
    return *STDOUT if $dump;


    my $pipe;
    unless( open $pipe, '|-', "gnuplot --persist" )
    {
      say STDERR "Couldn't launch gnuplot";
      return;
    }
    return $pipe;
  }

  sub parseOptions
  {
    my $options = shift;

    # if no options are defined, I'm done
    my $defaultsOnly;
    $defaultsOnly = 1 unless keys %$options;

    # set some defaults
    $options->{ maxcurves } = 100 unless defined $options->{ maxcurves };

    return if $defaultsOnly;


    # make sure I'm not passed invalid combinations of options
    {
      if ( $options->{'3d'} )
      {
        if ( defined $options->{y2min} || defined $options->{y2max} || defined $options->{y2} )
        { barf "'3d' does not make sense with 'y2'...\n"; }

        if( $options->{style} =~ /circles/ )
        { barf "At this time gnuplot does not support 3d plotting with circles."; }
      }
      else
      {
        if (!$options->{colormap})
        {
          if ( defined $options->{zmin} || defined $options->{zmax} || defined $options->{zlabel} )
          { barf "'zmin'/'zmax'/'zlabel' only makes sense with '3d' or 'colormap'\n"; }
        }

        if ( defined $options->{square_xy} )
        { barf "'square'_xy only makes sense with '3d'\n"; }
      }
    }


    my $cmd   = '';


    # set the global style
    {
      my $style = '';

      $style .= " $options->{style}" if $options->{style};
      $cmd .= "set style data $style\n" if $style;
    }

    # grid on by default
    if( !$options->{nogrid} )
    { $cmd .= "set grid\n"; }

    # set the plot bounds
    {
      # If a bound isn't given I want to set it to the empty string, so I can communicate it simply
      # to gnuplot
      $options->{xmin}  = '' unless defined $options->{xmin};
      $options->{xmax}  = '' unless defined $options->{xmax};
      $options->{ymin}  = '' unless defined $options->{ymin};
      $options->{ymax}  = '' unless defined $options->{ymax};
      $options->{y2min} = '' unless defined $options->{y2min};
      $options->{y2max} = '' unless defined $options->{y2max};
      $options->{zmin}  = '' unless defined $options->{zmin};
      $options->{zmax}  = '' unless defined $options->{zmax};

      # if any of the ranges are given, set the range
      $cmd .= "set xrange [$options->{xmin}:$options->{xmax}]\n"    if length( $options->{xmin}  . $options->{xmax} );
      $cmd .= "set yrange [$options->{ymin}:$options->{ymax}]\n"    if length( $options->{ymin}  . $options->{ymax} );
      $cmd .= "set y2range [$options->{y2min}:$options->{y2max}]\n" if length( $options->{y2min} . $options->{y2max} );

      if ($options->{colormap})
      {
        $cmd .= "set cbrange [$options->{zmin}:$options->{zmax}]\n" if length( $options->{zmin} . $options->{zmax} );
      }
      else
      {
        $cmd .= "set zrange [$options->{zmin}:$options->{zmax}]\n"    if length( $options->{zmin}  . $options->{zmax} );
      }
    }

    # set the curve labels, titles
    {
      $cmd .= "set xlabel  \"$options->{xlabel }\"\n" if defined $options->{xlabel};
      $cmd .= "set ylabel  \"$options->{ylabel }\"\n" if defined $options->{ylabel};
      $cmd .= "set zlabel  \"$options->{zlabel }\"\n" if defined $options->{zlabel};
      $cmd .= "set y2label \"$options->{y2label}\"\n" if defined $options->{y2label};
      $cmd .= "set title   \"$options->{title  }\"\n" if defined $options->{title};
    }

    # handle a requested square aspect ratio
    {
      # set a square aspect ratio. Gnuplot does this differently for 2D and 3D plots
      if ( $options->{'3d'})
      {
        if    ($options->{square})    { $cmd .= "set view equal xyz\n"; }
        elsif ($options->{square_xy}) { $cmd .= "set view equal xy\n" ; }
      }
      else
      {
        if( $options->{square} ) { $cmd .= "set size ratio -1\n"; }
      }
    }



    # handle multiple-range styles, such as colormaps and circles
    $options->{valuesPerPoint} = 1; # by default, 1 value for each point
    {
      if( $options->{colormap} )
      {
        # colormap styles all curves with palette. Seems like there should be a way to do this with a
        # global setting, but I can't get that to work
        $options->{style_allcurves} = 'palette';
      }


      if( $options->{extraValuesPerPoint})
      { $options->{valuesPerPoint} += $options->{extraValuesPerPoint}; }

      if( $options->{colormap} )
      { $options->{valuesPerPoint}++; }

      if( defined $options->{style} && $options->{style} =~ /circles/ )
      { $options->{valuesPerPoint}++; }
    }


    # handle hardcopy output
    {
      if ( $options->{hardcopy})
      {
        my $outputfile = $options->{hardcopy};
        my ($outputfileType) = $outputfile =~ /\.(eps|ps|pdf|png)$/;
        if (!$outputfileType)
        { barf "Only .eps, .ps, .pdf and .png hardcopy output supported\n"; }

        my %terminalOpts =
          ( eps  => 'postscript solid color enhanced eps',
            ps   => 'postscript solid color landscape 10',
            pdf  => 'pdfcairo solid color font ",10" size 11in,8.5in',
            png  => 'png size 1280,1024' );

        $cmd .= "set terminal $terminalOpts{$outputfileType}\n";
        $cmd .= "set output \"$outputfile\"\n";
      }
    }


    # add the extra global options
    {
      if($options->{extracmds})
      {
        foreach (@{$options->{extracmds}})
        { $cmd .= "$_\n"; }
      }
    }

    return $cmd;
  }
}

# the main API function to generate a plot. Input arguments are a bunch of piddles optionally
# followed by a bunch of options for each curve.
#
# The input piddles are a single domain piddle followed by some range piddles.
# If the domain is null, sequential integers (0,1,2...) are used.
# If the domain is null, and we're plotting in 3D, we use an appropriately-sized grid (see below)
# If only a single piddle argument is given, domain==null is assumed
#
# For 3d plots the domain is an Npoints-2-... piddle that contains the (x,y) values for each point

# If the domain is null and we're plotting in 3D, a grid based on the first
# 2-dimensions of the range is used. For instance if the first 2 dims of a range
# are 3x5, the range is plotted on a 3x5 grid with x in 0..2 and y in 0..4

#
# For plots that have more than one value per range, ranges are interpreted to be
# Npoints-NperRange-... piddles
#
# The ranges for each curve can be given in separate arguments to plot(), or stacked in the ranges
# piddles
sub plot
{
  barf( "Plot called with no arguments") unless @_;

  my $this;

  if(!defined ref $_[0] || ref $_[0] ne 'PDL::Gnuplot')
  {
    my $plotOptions = {};
    if(defined ref $_[0] && ref $_[0] eq 'HASH')
    {
      $plotOptions = shift;
    }

    $this = PDL::Gnuplot->new($plotOptions);
  }
  else
  {
    $this = shift;
  }

  my $pipe        = $this->{pipe};
  my $plotOptions = $this->{options};

  # split the arguments into a list of piddles (data to plot) and everything else (options)
  my ($datalist, $options) = part {defined ref($_) && ref($_) eq 'PDL' ? 0 : 1} @_;

  if( scalar @$datalist == 0)
  { barf "plot() was not given any data"; }

  my $domain;
  if(@$datalist == 1) { $domain = null; }
  else                { $domain = shift @$datalist; }

  my $rangelist = $datalist;

  # if no domain is specified, make a default one
  if($domain->nelem == 0)
  {
    if( !$plotOptions->{'3d'} )
    {
      # in 2D, the default domain is simply increasing integers
      $domain = sequence($rangelist->[0]->dim(0));
    }
    else
    {
      # in 3D, the first 2 dimensions of every range are plotted in a grid
      my $domaindims;
      foreach my $range(@$rangelist)
      {
        my @dims = $range->dims;
        barf "plot() got a null range" if(! @dims);

        # a 1D range gets a degenerate dimension
        push( @dims, 1) if(@dims == 1);

        if(! $domaindims)
        {
          # store the domain dimensions if I don't already have them
          $domaindims = \@dims;

          # generate an Nx2 domain useable by the rest of the code
          my $Npoints = $dims[0] * $dims[1];
          $domain = zeros(@dims[0..1])->ndcoords->reshape(2,$Npoints)->transpose;
        }
        else
        {
          # if I do have them, make sure they match
          if($domaindims->[0] != $dims[0] || $domaindims->[1] != $dims[1])
          { barf "plot() grid domain mismatch"; }
        }

        # make the range dimensionality reflect the domain
        $range = $range->clump(2);
      }
    }
  }

  # make sure the domain is appropriately sized for 3d plots. Domain should have dims (N,2,M)
  # This would describe M different domains each with N (x,y) pairs
  if ( $plotOptions->{'3d'} && $domain->dim(1) != 2 )
  {
    my @dims = $domain->dims;
    barf "plot() was asked to make a 3d plot with a non-2 2nd dim. Domain dims: (@dims).";
  }

  # Make sure the domain and ranges describe the same number of data points
  foreach my $range (@$rangelist)
  {
    my $rangedim  = $range ->dim(0);
    my $domaindim = $domain->dim(0);
    if ( $domaindim != $rangedim )
    { barf "plot() domain-range size mismatch. Domain: $domaindim, a range: $rangedim"; }
  }

  # if we're plotting something that has more than one value for every point, make sure the
  # dimensions support this
  if( $plotOptions->{valuesPerPoint} > 1)
  {
    foreach my $range (@$rangelist)
    {
      if( $range->ndims < 2 )
      { barf "Asked to plot more than 1 value per point, but got a range that was only 1D (one value only)"; }

      if( $range->dim(1) != $plotOptions->{valuesPerPoint} )
      {
        my $havedim = $range->dim(1);
        my $wantdim = $plotOptions->{valuesPerPoint};
        barf "Expected $wantdim values per point, but got piddle with $havedim";
      }
    }
  }

  # I now have the domain piddle and some piddles containing the ranges. I can either have each
  # curve in a separate 'ranges' piddle, or the ranges could be stacked together in one piddle.  I
  # stack all my ranges into a single regardless and let PDL threading sort out the exact mappings
  # later
  our ($a, $b);
  my $ranges =
    # glue all the range data together into one piddle right after....
    List::Util::reduce {$a->glue (2, $b)}

    # ... collapsing all the extra dims of each range argument into one dim, right after...
    map                {$_->ndims > 3 ? $_->clump(2..$_->ndims-1) : $_}

    # ... making sure there's an extra dim for valuesPerPoint, creating one if needed
    map                {$plotOptions->{valuesPerPoint} == 1 ? $_->dummy(1) : $_} @$rangelist;


  # if we have a single curve, add a dummy dimension to allow the generic functions to work
  $ranges = $ranges->dummy(2) if $ranges->ndims < 3;

  # I now have a domain and an appropriately-sized range piddle. PDL threading can do the rest
  my $N = numCurves($domain, $ranges,
                    $plotOptions->{'3d'} ? 2 : 1);

  if($N > $plotOptions->{maxcurves})
  {
    barf <<EOB;
Tried to exceed the 'maxcurves' setting.\n
Invoke with a higher 'maxcurves' option if you really want to do this.\n
EOB

  }

  say $pipe plotcmd($N, $options, $plotOptions->{'3d'}, $plotOptions->{style_allcurves} );

  if( ! $plotOptions->{'3d'} )
  { _writedata_1d_domain($domain, $ranges, $pipe); }
  else
  { _writedata_2d_domain($domain, $ranges, $pipe); }
  flush $pipe;


  # compute how many curves have been passed in, assuming things thread
  sub numCurves
  {
    my ($domain, $ranges, $firstDataDim) = @_;

    # ranges should have dims (pointIndex, valueIndex, curveIndex)
    # so here I only need to look at curveIndex
    if($ranges->ndims != 3)
    { barf "numCurves got ranges with dim " . $ranges->ndims . ". It should be 3. This is a bug!"; }

    my $N = 1;

    # I make sure the range curves dimension matches up with the corresponding dimension in the
    # domain
    my ($dim0, $dim1) = minmax(pdl($domain->dim($firstDataDim), $ranges->dim(2)));
    if ($dim0 == 1 || $dim0 == $dim1)
    { $N *= $dim1; }
    else
    {
      my @xdims = $domain->dims;
      my @ydims = $ranges->dims;
      barf "plot() was given non-threadable arguments. Mismatched dims: (@xdims) and (@ydims)";
    }

    # Now I add all the extra domain dimensions to my counter
    for my $domainDim ($firstDataDim+1..$domain->ndims-1)
    { $N *= $domain->dim($domainDim); }

    return $N;
  }

  # generates the gnuplot command to generate the plot. The curve options are parsed here
  sub plotcmd
  {
    my ($N, $options, $is3d, $style_allcurves) = @_;

    # remove any options that exceed my data
    $options //= [];
    splice( @$options, $N ) if @$options > $N;

    # fill the options list to match the number of curves in length
    push @$options, ({}) x ($N - @$options);

    my $cmd = '';

    # if anything is to be plotted on the y2 axis, set it up
    if( grep {$_->{y2}} @$options )
    {
      if( $is3d )
      { barf "3d plots don't have a y2 axis"; }

      $cmd .= "set ytics nomirror\n";
      $cmd .= "set y2tics\n";
    }

    if($is3d) { $cmd .= 'splot '; }
    else      { $cmd .= 'plot ' ; }
    $cmd .= join(',', map {"'-' " . optioncmd($_, $style_allcurves)} @$options);

    return $cmd;



    # parses a curve option
    sub optioncmd
    {
      my $option          = shift;
      my $style_allcurves = shift;

      my $cmd = '';

      if( defined $option->{legend} )
      { $cmd .= "title \"$option->{legend}\" "; }
      else
      { $cmd .= "notitle "; }

      $cmd .= "$option->{style} " if defined $option->{style};
      $cmd .= "$style_allcurves " if defined $style_allcurves;
      $cmd .= "axes x1y2 "        if defined $option->{y2};

      return $cmd;
    }
  }
}

thread_define '_writedata_1d_domain(x(n); y(n,valuesInPoint)), NOtherPars => 1', over
{
  my $pipe = pop @_;
  wcols $_[0], $_[1]->dog, $pipe;
  say $pipe 'e';
};

thread_define '_writedata_2d_domain(xy(n,m=2); z(n,valuesInPoint)), NOtherPars => 1', over
{
  my $pipe = pop @_;
  wcols $_[0]->dog, $_[1]->dog, $pipe;
  say $pipe 'e';
};

1;
