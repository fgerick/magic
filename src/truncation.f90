module truncation
   !
   ! This module defines the grid points and the truncation 
   !

   use parallel_mod
   use precision_mod, only: cp
   use logic
   use useful, only: abortRun
   use output_data, only: tag

   
   implicit none
   
   public
   
   !---------------------------------
   !-- Global Dimensions:
   !---------------------------------
   !   
   !   minc here is sort of the inverse of mres in SHTns. In MagIC, the number
   !   of m modes stored is m_max/minc+1. In SHTns, it is simply m_max. 
   !   Conversely, there are m_max m modes in MagIC, though not all of them are 
   !   effectivelly stored/computed. In SHTns, the number of m modes is 
   !   m_max*minc+1 (therein called mres). This makes things very confusing 
   !   specially because lm2 and lmP2 arrays (and their relatives) store m_max 
   !   m points, and sets those which are not multiple of minc to 0.
   !   
   !   In other words, this:
   !   > call shtns_lmidx(lm_idx, l_idx, m_idx/minc)
   !   returns the same as 
   !   > lm_idx = lm2(l_idx, m_idx)
   !   
   !-- TODO: ask Thomas about converting all variables associated with the 
   !   global geometry (e.g. n_r_max, n_phi_max) to the "glb" suffix
   !   (e.g. n_r_glb, n_phi_glb) to highlight the differences
   
   character(len=20), public :: rIter_type
   character(len=20), public :: mlo_dist_method ! Read from namelist

   !-- Basic quantities:
   integer :: n_r_max       ! number of radial grid points
   integer :: n_cheb_max    ! max degree-1 of cheb polynomia
   integer :: n_phi_tot     ! number of longitude grid points
   integer :: n_r_ic_max    ! number of grid points in inner core
   integer :: n_cheb_ic_max ! number of chebs in inner core
   integer :: minc          ! basic wavenumber, longitude symmetry  
   integer :: nalias        ! controls dealiasing in latitude
   logical :: l_axi         ! logical for axisymmetric calculations
   character(len=72) :: radial_scheme ! radial scheme (either Cheybev of FD)
   real(cp) :: fd_stretch    ! regular intervals over irregular intervals
   real(cp) :: fd_ratio      ! drMin over drMax (only when FD are used)
   integer :: fd_order       ! Finite difference order (for now only 2 and 4 are safe)
   integer :: fd_order_bound ! Finite difference order on the  boundaries
   integer :: n_r_cmb
   integer :: n_r_icb
 
   !-- Derived quantities:
   integer :: n_phi_max   ! absolute number of phi grid-points
   integer :: n_theta_max ! number of theta grid-points
   integer :: nlat_padded ! number of theta grid-points with padding included
   integer :: n_theta_axi ! number of theta grid-points (axisymmetric models)
   integer :: l_max       ! max degree of Plms
   integer :: m_max       ! max order of Plms
   integer :: n_m_max     ! max number of ms (different oders)
   integer :: lm_max      ! number of l/m combinations
   integer :: lmP_max     ! number of l/m combination if l runs to l_max+1
   integer :: n_r_tot     ! total number of radial grid points
 
   !--- Now quantities for magnetic fields:
   !    Set lMag=0 if you want to save this memory (see c_fields)!
   integer :: lMagMem       ! Memory for magnetic field calculation
   integer :: n_r_maxMag    ! Number of radial points to calculate magnetic field
   integer :: n_r_ic_maxMag ! Number of radial points to calculate IC magnetic field
   integer :: n_r_totMag    ! n_r_maxMag + n_r_ic_maxMag
   integer :: l_maxMag      ! Max. degree for magnetic field calculation
   integer :: lm_maxMag     ! Max. number of l/m combinations for magnetic field calculation
 
   !-- Movie memory control:
   integer :: lMovieMem      ! Memory for movies
   integer :: ldtBMem        ! Memory for movie output
   integer :: lm_max_dtB     ! Number of l/m combinations for movie output
   integer :: n_r_max_dtB    ! Number of radial points for movie output
   integer :: n_r_ic_max_dtB ! Number of IC radial points for movie output
   integer :: lmP_max_dtB    ! Number of l/m combinations for movie output if l runs to l_max+1
 
   !--- Memory control for stress output:
   integer :: lStressMem     ! Memory for stress output
   integer :: n_r_maxStr     ! Number of radial points for stress output
   integer :: n_theta_maxStr ! Number of theta points for stress output
   integer :: n_phi_maxStr   ! Number of phi points for stress output
   
   !---------------------------------
   !-- Distributed Dimensions
   !---------------------------------
   !  
   !   Notation for continuous variables:
   !   dist_V(i,1) = lower bound of direction V in coord_r i
   !   dist_V(i,2) = upper bound of direction V in coord_r i
   !   dist_V(i,0) = shortcut to dist_V(i,2) - dist_V(i,1) + 1
   !   
   !   Because continuous variables are simple, we can define some shortcuts:
   !   l_V: dist_V(this_rank,1)
   !   u_V: dist_V(this_rank,2)
   !   n_V_loc: u_V - l_V + 1  (number of local points in V direction)
   !   n_V_max: global dimensions of variable V. Basically, the result of 
   !   > MPI_ALLREDUCE(n_V_loc,n_V_max,MPI_SUM)
   !   
   !   For discontinuous variables:
   !   dist_V(i,0)  = how many V points are there for coord_r i
   !   dist_V(i,1:) = an array containing all of the V points in coord_r i of 
   !      communicator comm_V. Since the number of points is not necessarily 
   !      the same in all ranks, make sure that all points of coord_r i are in 
   !      dist_V(i,1:n_V_loc) and the remaining dist_V(i,n_V_loc+1:) points 
   !      are set to a negative number.
   !      
   !   Notice that n_lm_loc, n_lmP_loc, n_lm, n_lmP and etc are not the same
   !   as lm_max and lmP_max. The former stores the number of *local* points,
   !   the later stores the total number of points in all ranks.
   !   
   !   V_tsid(x) = the inverse of dist_V (quite literally; the name is just 
   !      written backwards; sorry!) V_tsid(x) returns which coord_V of 
   !      comm_V stores/computes the point x. This is not necessary for all
   !      dist_V, specially not for the contiguous ones (e.g. dist_r)
   !   

   !-- Distributed Grid Space 
   integer, allocatable, protected :: dist_theta(:,:)
   integer, allocatable, protected :: dist_r(:,:)
   !@TODO> I have to remove the protected argument otherwise it cannot be
   !overwritten in shtns.f90 when padding is requested
   integer :: n_theta_loc, nThetaStart, nThetaStop
   integer, protected :: n_r_loc, nRstart, nRstop
   integer, protected :: nR_per_rank ! kinda misleading name, should be deleted later; use n_r_loc instead; kept only to ease merge
   
   !   Helpers
   integer, protected :: nRstartMag
   integer, protected :: nRstartChe
   integer, protected :: nRstartDC 
   integer, protected :: nRstopMag 
   integer, protected :: nRstopChe 
   integer, protected :: nRstopDC  
   integer, protected :: n_lmMag_loc
   integer, protected :: n_lmChe_loc
   integer, protected :: n_lmTP_loc
   integer, protected :: n_lmDC_loc
   
   !-- Distributed LM-Space
   ! 
   !   Just for clarification:
   !   n_lm_loc:  total number of l and m points in this coord_r
   !   n_lmP_loc: total number of l and m points (for l_max+1) in this coord_r
   !   
   !   n_m_array: if m_max is not divisible by n_ranks_m, some ranks will 
   !     receive more m points than others. 
   !     n_m_array is basically MPI_ALLREDUCE(n_m_array,n_m_loc,MPI_MAX)
   !     It is also the size of the 2nd dimension of dist_m.
   !     Set the extra dist_m(i,1:n_m_loc) to the points in coord_r i and the 
   !     remaining dist_m(i,n_m_loc+1:n_m_array) to a negative number. 
   !   
   !        allocatable, protected :: dist_r(:,:) => same as dist_r from Grid Space
   integer, allocatable, protected :: dist_m(:,:), m_tsid(:)
   integer, allocatable, protected :: dist_n_lm(:)
   integer, allocatable, protected :: dist_n_lmP(:)
   integer, protected :: n_m_loc, n_lmP_loc
   integer, protected :: n_mloMag_loc
   integer, protected :: n_mloChe_loc
   integer, protected :: n_mloDC_loc 
   integer, protected :: n_m_array
   integer :: n_lm_loc ! corrected in blocking.f90 if n_ranks_theta=1...
   
   !-- Distributed ML-Space
   !   
   !   The key variable here is dist_mlo. It contains the tuplets associated
   !   with each coord_r.
   !   
   !   dist_mlo(irank_mo,irank_lo,j,1) = value of m in the j-th tuplet in irank.
   !   dist_mlo(irank_mo,irank_lo,j,2) = value of l in the j-th tuplet in irank.
   !   
   !   Everything should be written such that the tuplets given in this array
   !   are respected. The code should be agnostic to what order or what criteria
   !   was chosen to build this variable. n_mlo_array gives the length of the 
   !   second dimension of this array.
   !   
   !-- TODO: dist_mlo is created in distribute_mlo, but this is rather poorly
   !   optimized. I'm afraid that a reasonable distribution would require a very
   !   complex routine which deals with graphs and trees.
   !
   integer, allocatable, protected :: dist_mlo(:,:,:,:)
   integer, allocatable, protected :: dist_n_mlo(:,:)
   integer, protected :: n_mo_loc, n_lo_loc
   integer, protected :: n_mlo_array, mlo_max
   integer :: n_mlo_loc ! corrected in blocking.f90 if n_ranks_theta=1...
   
   type, public :: load
      integer :: nStart
      integer :: nStop
      integer :: n_per_rank
   end type load
   
   type(load), public, allocatable :: radial_balance(:)
   integer :: n_geometry_file
   character(len=72) :: geometry_file
   
contains

   subroutine initialize_truncation

      integer :: n_r_maxML,n_r_ic_maxML,n_r_totML,l_maxML,lm_maxML
      integer :: lm_max_dL,lmP_max_dL,n_r_max_dL,n_r_ic_max_dL
      integer :: n_r_maxSL,n_theta_maxSL,n_phi_maxSL

      if ( .not. l_axi ) then
         ! absolute number of phi grid-points
         n_phi_max=n_phi_tot/minc

         ! number of theta grid-points
         n_theta_max=n_phi_tot/2

         ! max degree and order of Plms
         l_max=(nalias*n_theta_max)/30 
         m_max=(l_max/minc)*minc
      else
         n_theta_max=n_theta_axi
         n_phi_max  =1
         n_phi_tot  =1
         minc       =1
         l_max      =(nalias*n_theta_max)/30 
         m_max      =0
      end if

      ! this will be possibly overwritten when SHTns is used
      nlat_padded=n_theta_max

      ! max number of ms (different oders)
      n_m_max=m_max/minc+1

      ! number of l/m combinations
      lm_max=m_max*(l_max+1)/minc - m_max*(m_max-minc)/(2*minc)+(l_max+1-m_max)
      ! number of l/m combination if l runs to l_max+1
      lmP_max=lm_max+n_m_max

      ! total number of radial grid points
      n_r_tot = n_r_max
      if ( l_cond_ic ) n_r_tot=n_r_max+n_r_ic_max

      !--- Now quantities for magnetic fields:
      !    Set lMag=0 if you want to save this memory (see c_fields)!
      n_r_maxML     = lMagMem*n_r_max
      n_r_ic_maxML  = lMagMem*n_r_ic_max
      n_r_totML     = lMagMem*n_r_tot
      l_maxML       = lMagMem*l_max
      lm_maxML      = lMagMem*lm_max
      n_r_maxMag    = max(1,n_r_maxML)
      n_r_ic_maxMag = max(1,n_r_ic_maxML)
      n_r_totMag    = max(1,n_r_totML)
      l_maxMag      = max(1,l_maxML)
      lm_maxMag     = max(1,lm_maxML)

      !-- Movie memory control:
      lm_max_dL    =ldtBMem*lm_max
      lmP_max_dL   =ldtBMem*lmP_max
      n_r_max_dL   =ldtBMem*n_r_max
      n_r_ic_max_dL=ldtBMem*n_r_ic_max
      lm_max_dtB    =max(lm_max_DL,1) 
      lmP_max_dtB   =max(lmP_max_DL,1)
      n_r_max_dtB   =max(n_r_max_DL,1)
      n_r_ic_max_dtB=max(n_r_ic_max_DL,1)

      !--- Memory control for stress output:
      n_r_maxSL     =lStressMem*n_r_max
      n_theta_maxSL =lStressMem*n_theta_max
      n_phi_maxSL   =lStressMem*n_phi_max
      n_r_maxStr    =max(n_r_maxSL,1)
      n_theta_maxStr=max(n_theta_maxSL,1)
      n_phi_maxStr  =max(n_phi_maxSL,1)
      
   end subroutine initialize_truncation
   
   subroutine initialize_radial_data(n_r_max)
      !
      ! This subroutine is used to set up the MPI decomposition in the
      ! radial direction
      !
      integer, intent(in) :: n_r_max ! Number of radial grid points

      n_r_cmb=1
      n_r_icb=n_r_max

      allocate(radial_balance(0:n_ranks_r-1))
      call getBlocks(radial_balance, n_r_max, n_ranks_r)   

      nRstart = radial_balance(coord_r)%nStart
      nRstop = radial_balance(coord_r)%nStop
      n_r_loc = radial_balance(coord_r)%n_per_rank
      nR_per_rank = n_r_loc

      if ( l_mag ) then
         nRstartMag = nRstart
         nRstopMag  = nRstop
      else
         nRstartMag = 1
         nRstopMag  = 1
      end if

      if ( lVerbose ) then
         write(*,"(4(A,I4))") "On coord_r ",coord_r," nR is in (", &
               nRstart,",",nRstop,"), nR_per_rank is ",nR_per_rank
      end if

   end subroutine initialize_radial_data
!------------------------------------------------------------------------------
   subroutine finalize_radial_data

      deallocate( radial_balance )

   end subroutine finalize_radial_data
   
!--------------------------------------------------------------------------------
   subroutine checkTruncation
      !  This function checks truncations and writes it
      !  into STDOUT and the log-file.                                 
      !  MPI: called only by the processor responsible for output !  

      if ( minc < 1 ) then
         call abortRun('! Wave number minc should be > 0!')
      end if
      if ( mod(n_phi_tot,minc) /= 0 .and. (.not. l_axi) ) then
         call abortRun('! Number of longitude grid points n_phi_tot must be a multiple of minc')
      end if
      if ( mod(n_phi_max,4) /= 0 .and. (.not. l_axi) ) then
         call abortRun('! Number of longitude grid points n_phi_tot/minc must be a multiple of 4')
      end if
      if ( mod(n_phi_tot,16) /= 0 .and. (.not. l_axi) ) then
         call abortRun('! Number of longitude grid points n_phi_tot must be a multiple of 16')
      end if
      if ( n_phi_max/2 <= 2 .and. (.not. l_axi) ) then
         call abortRun('! Number of longitude grid points n_phi_tot must be larger than 2*minc')
      end if

      if ( n_theta_max <= 2 ) then
         call abortRun('! Number of latitude grid points n_theta_max must be larger than 2')
      end if
      if ( mod(n_theta_max,4) /= 0 ) then
         call abortRun('! Number n_theta_max of latitude grid points be a multiple must be a multiple of 4')
      end if
      if ( n_cheb_max > n_r_max ) then
         call abortRun('! n_cheb_max should be <= n_r_max!')
      end if
      if ( n_cheb_max < 1 ) then
         call abortRun('! n_cheb_max should be > 1!')
      end if

   end subroutine checkTruncation
   
   !----------------------------------------------------------------------------
   subroutine initialize_distributed_geometry
      !   
      !   Author: Rafael Lago, MPCDF, June 2018
      
      if ( l_master_rank ) then
         geometry_file = 'dist_geometry.'//tag
         open(newunit=n_geometry_file, file=geometry_file, &
         &    status='unknown', position='append')
      end if
      !   
      
      call distribute_gs
      call print_contiguous_distribution(dist_theta, n_ranks_theta, 'θ')
      call print_contiguous_distribution(dist_r, n_ranks_r, 'r')
      
      call distribute_lm
      call print_discontiguous_distribution(dist_m, n_m_array, n_ranks_m, 'm')

      call distribute_mlo
      call print_mlo_distribution_summary
      
      if (l_verb_paral) call print_mlo_distribution
   end subroutine initialize_distributed_geometry
   
   !----------------------------------------------------------------------------
   subroutine finalize_distributed_geometry
      !   
      !   Author: Rafael Lago, MPCDF, June 2018
      !   
      
      !-- Finalize global geometry
      !   lol
      
      !-- Finalize distributed grid space
      deallocate(dist_theta)
      deallocate(dist_r)
      
      !-- Finalize distributed lm
      deallocate(dist_m, m_tsid)
      
      !-- Finalize distributed mlo
      deallocate(dist_mlo)
      deallocate(dist_n_mlo)
      
      if ( l_master_rank ) then
         close(n_geometry_file)
      end if
      
   end subroutine finalize_distributed_geometry

   !----------------------------------------------------------------------------
   subroutine distribute_gs
      !   
      !   Distributes the radial points and the θs. Every φ point is local.
      !   
      !   Author: Rafael Lago, MPCDF, June 2018
      !   
      
      !-- Distribute Grid Space θ
      !
      allocate(dist_theta(0:n_ranks_theta-1,0:2))
      call distribute_contiguous_last(dist_theta,n_theta_max,n_ranks_theta)
      dist_theta(:,0) = dist_theta(:,2) - dist_theta(:,1) + 1
      nThetaStart = dist_theta(coord_theta,1)
      nThetaStop = dist_theta(coord_theta,2)
      n_theta_loc = nThetaStop - nThetaStart + 1
      
      !-- Distribute Grid Space r
      !   I'm not sure what happens if n_r_cmb/=1 and n_r_icb/=n_r_max
      allocate(dist_r(0:n_ranks_r-1,0:2))
      call distribute_contiguous_last(dist_r,n_r_max,n_ranks_r)
      
      !-- Take n_r_cmb into account now
      !-- TODO check if this is correct
!       dist_r(:,1:2) = dist_r(:,1:2) !+ n_r_cmb - 1
      
      dist_r(:,0) = dist_r(:,2) - dist_r(:,1) + 1
      n_r_loc = dist_r(coord_r,0)
      nRstart = dist_r(coord_r,1)
      nRstop = dist_r(coord_r,2)
      
      nRstartMag = 1
      nRstartChe = 1
      nRstartDC  = 1
      nRstopMag = 1
      nRstopChe = 1
      nRstopDC  = 1
      if (l_mag          ) nRstartMag = nRstart
      if (l_chemical_conv) nRstartChe = nRstart
      if (l_double_curl  ) nRstartDC  = nRstart
      if (l_mag          ) nRstopMag = nRstop
      if (l_chemical_conv) nRstopChe = nRstop
      if (l_double_curl  ) nRstopDC  = nRstop
      
   end subroutine distribute_gs
   
   !----------------------------------------------------------------------------
   subroutine distribute_lm
      !   
      !   Distributes the m's from the LM-space. It re-uses the distribution
      !   of the radial points obtained from distribute_gs. Every l point is
      !   local.
      !   
      !   Author: Rafael Lago, MPCDF, June 2018
      !   
      integer :: icoord_m, mi, m
      
      n_m_array = ceiling(real(n_m_max) / real(n_ranks_m))
      allocate(dist_m(0:n_ranks_m-1, 0:n_m_array))
      allocate(dist_n_lm(0:n_ranks_m-1))
      allocate(dist_n_lmP(0:n_ranks_m-1))
      
      call distribute_discontiguous_snake(dist_m, n_m_array, n_m_max, n_ranks_m)
      
      !-- The function above distributes a list of points [p1, p2, (...), pN].
      !   Now we resolve what those points mean in practice. In this case
      !   it is pretty simple: p(x) = (x-1)*minc
      dist_m(:,1:) = (dist_m(:,1:)-1)*minc
      
      !-- Formula for the number of lm-points in each coord_r:
      !   n_lm = Σ(l_max+1 - m) = (l_max+1)*n_m - Σm
      !   for every m in the specified coord_r. Read the
      !   comment in "Distributed LM-Space" section at the beginning of this 
      !   module for more details on that
      dist_n_lm = (l_max+1)*dist_m(:,0) - sum(dist_m(:,1:), dim=2, mask=dist_m(:,1:)>=0)
      dist_n_lmP = dist_n_lm + dist_m(:,0)       
      
      n_m_loc   = dist_m(coord_m,0)
      n_lm_loc  = dist_n_lm(coord_m)
      n_lmP_loc = dist_n_lmP(coord_m)
      
      n_lmMag_loc = 1
      n_lmChe_loc = 1
      n_lmTP_loc  = 1
      n_lmDC_loc  = 1
      if (l_mag          ) n_lmMag_loc = n_lm_loc
      if (l_chemical_conv) n_lmChe_loc = n_lm_loc
      if (l_double_curl  ) n_lmDC_loc  = n_lm_loc
      
      !-- Fills the reverse mapping
      !
      allocate(m_tsid(0:l_max))
      m_tsid = -1
      do icoord_m=0,n_ranks_m-1
         do mi=1,dist_m(icoord_m,0)
            m = dist_m(icoord_m,mi)
            if (m<0) cycle
            m_tsid(m) = icoord_m
         end do
      end do
      
   end subroutine distribute_lm
   !----------------------------------------------------------------------------
   subroutine distribute_mlo
      !   
      !   Distributes the l's and the m's from the ML-space. Every r point is 
      !   local.
      !   
      !   This function will keep the m's distribution untouched. Only the l's
      !   will be shuffled around. In this framework, we will always have:
      !   
      !   coord_m [m in (l,m,r) coordinates] = coord_mo [m in (r,m,l) coordinates]
      !   
      !   1) Splits n_lm(coord_m=coord_mo) amongst n_rank_r = n_rank_lo ranks.
      !   
      !   Author: Rafael Lago, MPCDF, June 2018
      !   
      integer :: tmp(0:n_ranks_r-1,0:2)
      integer :: icoord_mo, icoord_lo
      integer :: l, m, i
      
      allocate(dist_n_mlo(0:n_ranks_mo-1, 0:n_ranks_lo-1))
      
      !-- Assign the (m,l) pairs to each coord_mo and coord_lo
      !   After calling one of these functions the following must be determined:
      !     dist_mlo
      !     dist_n_mlo
      if (trim(mlo_dist_method)=="mfirst") then
         call distribute_mlo_mfirst
      else if (trim(mlo_dist_method)=="lfirst") then
         call distribute_mlo_lfirst
      else if (trim(mlo_dist_method)=="lexicographic") then   
         call distribute_mlo_lexicographic
      else 
         print *, " Invalid mlo_dist_method given in Namelists."
         print *, " Ignoring and using 'mfirst'..."
         call distribute_mlo_mfirst
      end if
      
      !-- Count how many different lo's are local
      n_lo_loc = 0
      do l=0,l_max
         if (any(dist_mlo(coord_mo,coord_lo,:,2)==l)) n_lo_loc = n_lo_loc + 1
      end do
      
      !-- Count how many different mo's are local
      n_mo_loc = 0
      do m=0,l_max
         if (any(dist_mlo(coord_mo,coord_lo,:,1)==m)) n_mo_loc = n_mo_loc + 1
      end do
      
      !-- Count how many (m,l) pairs are local (in case it differs from 
      !   the original estimation of the dist_n_mlo variable)
      dist_n_mlo = count(dist_mlo(:,:,:,1)>=0, dim=3)
      
      if (sum(dist_n_mlo) /= lm_max) then
         print *, "Something went wrong while distributing mlo. Aborting!"
         print *, "sum(dist_n_mlo) = ", sum(dist_n_mlo), ", lm_max=", lm_max
         stop
      end if
      
      n_mlo_loc = dist_n_mlo(coord_mo,coord_lo)
      mlo_max = lm_max
      
      n_mloMag_loc = 1
      n_mloChe_loc = 1
      n_mloDC_loc  = 1
      if (l_mag          ) n_mloMag_loc = n_mlo_loc
      if (l_chemical_conv) n_mloChe_loc = n_mlo_loc
      if (l_double_curl  ) n_mloDC_loc  = n_mlo_loc
      
   end subroutine distribute_mlo
   
   !----------------------------------------------------------------------------   
   subroutine distribute_mlo_mfirst
      !
      !   This loop will distribute (m,l) points (for lmloop) with the following
      !   priority:
      !     - fair total number of points between ranks
      !     - minimize the l points in a rank
      !   
      !   This distribution is far from being optimal and should work just as 
      !   a placeholder.
      !   
      !   Author: Rafael Lago, MPCDF, June 2018
      !
      integer :: tmp_cont(0:n_ranks_r-1,0:2)
      integer :: icoord_mo, icoord_lo, irank
      integer :: l, m, m_idx, i
      integer :: taken(0:m_max, 0:l_max)
      
      dist_n_mlo = 0
      
      !-- Compute how many ml-pairs will be store in each rank
      !
      do icoord_mo=0,n_ranks_m-1
         tmp_cont = 0
         call distribute_contiguous_last(tmp_cont, dist_n_lm(icoord_mo), n_ranks_lo)
         do icoord_lo=0,n_ranks_lo-1
            dist_n_mlo(icoord_mo, icoord_lo) = tmp_cont(icoord_lo,2) - tmp_cont(icoord_lo,1) + 1
         end do
      end do
      
      !-- Assign the (m,l) pairs to each rank, according to the count of 
      !   ml-pairs in dist_n_mlo
      n_mlo_array = maxval(dist_n_mlo)
      allocate(dist_mlo(0:n_ranks_mo-1, 0:n_ranks_lo-1, n_mlo_array, 2))
      dist_mlo = -1
      
      taken = -1
      do m=0,m_max
         taken(m,m:l_max) =  (/(l, l=m,l_max,1)/)
      end do
      
      do icoord_mo=0,n_ranks_mo-1
         l = 0
         m_idx = 1
         do icoord_lo=0,n_ranks_lo-1
            
            irank = mpi_map%gsp2rnk(icoord_mo, icoord_lo)
            
            i = 1
            do while (i<=dist_n_mlo(icoord_mo, icoord_lo))
               if (m_idx>dist_m(icoord_mo,0)) then
                  m_idx = 1
                  l = l + 1
               end if
               
               m = dist_m(icoord_mo, m_idx)
               
               if (l<m) then
                  m_idx = m_idx + 1
                  cycle
               end if
               
               dist_mlo(icoord_mo, icoord_lo, i, 1) = m
               dist_mlo(icoord_mo, icoord_lo, i, 2) = l
               i = i + 1
               m_idx = m_idx + 1
            end do
            
         end do
      end do
      
   end subroutine distribute_mlo_mfirst
   
   !----------------------------------------------------------------------------   
   subroutine distribute_mlo_lfirst
      !
      !   This loop will now distribute the (m,l) pairs amongst all the 
      !   rank_mlo. It will make sure that each coord_mo will only keep the 
      !   (m,l) pairs whose m is in coord_m. This is aimed at reducing 
      !   communication. It will also follow the number of (m,l) points 
      !   that we saved in n_mlo input variable.
      !   
      !   This subroutine will minimize the number of m's in each coord_r by 
      !   looping over l first, and then over m while distributing the pairs.
      !   
      !   This is probably not what you want. This subroutine is here mostly
      !   for academic purposes and tests!
      !
      !   Author: Rafael Lago, MPCDF, June 2018
      !
      integer :: icoord_mo, icoord_lo
      integer :: n_l_array, n_l, l_min, k, mi, lj, n, l, m, n_lj
      
      integer, allocatable :: dist_l(:,:)
      
      ! Loop to count how many points are stored per rank
      do icoord_mo=0,n_ranks_mo-1
         ! Number of l points in icoord_mo
         l_min = minval(dist_m(icoord_mo, 1:dist_m(icoord_mo,0)))
         n_l = l_max - l_min + 1
         n_l_array = ceiling(real(n_l) / real(n_ranks_lo))
         allocate(dist_l(0:n_ranks_lo-1, 0:n_l_array))
         dist_l = -1
         
         ! Distribute l points with snake ordering
         call distribute_discontiguous_snake(dist_l, n_l_array, n_l, n_ranks_lo)
         ! The function above gives numbers from 1:n_l. 
         ! We want them from l_min:l_min+n_l, but in descending order:
         dist_l(:,1:) = l_max - (l_min + dist_l(:,1:) - 1) + l_min
         do icoord_lo=0, n_ranks_lo-1
            k = 1
            ! Loops lj backwards, otherwise the ls will be arranged backwards
            ! in memory
            do lj = dist_l(icoord_lo,0),1,-1
               l = dist_l(icoord_lo,lj)
               do mi=1, dist_m(icoord_mo,0)
                  m = dist_m(icoord_mo,mi)
                  if (l>=m) k = k + 1
               end do
            end do
            
            ! Stores number of mlo points in this rank_mo/rank_lo
            dist_n_mlo(icoord_mo, icoord_lo) = k-1
         end do
         deallocate(dist_l)
      end do
      
      ! Now that sizes are known, copy from tmp into dist_mlo
      n_mlo_array = maxval(dist_n_mlo)
      allocate(dist_mlo(0:n_ranks_mo-1, 0:n_ranks_lo-1, n_mlo_array, 2))
      dist_mlo = -1
      
      ! Essentially the same as the previous loop, but we 
      ! now store the values.
      do icoord_mo=0,n_ranks_mo-1
         
         ! Number of l points in icoord_mo
         l_min = minval(dist_m(icoord_mo, 1:dist_m(icoord_mo,0)))
         n_l = l_max - l_min + 1
         n_l_array = ceiling(real(n_l) / real(n_ranks_lo))
         allocate(dist_l(0:n_ranks_lo-1, 0:n_l_array))
         dist_l = -1
         
         ! Distribute l points with snake ordering
         call distribute_discontiguous_snake(dist_l, n_l_array, n_l, n_ranks_lo)
         ! The function above gives numbers from 1:n_l. 
         ! We want them from l_min:l_min+n_l, but in descending order:
         dist_l(:,1:) = l_max - (l_min + dist_l(:,1:) - 1) + l_min
         do icoord_lo=0, n_ranks_lo-1
            k = 1
            
            ! Loops lj backwards, otherwise the ls will be arranged backwards
            ! in memory
            do lj = dist_l(icoord_lo,0),1,-1
               l = dist_l(icoord_lo,lj)
               do mi=1, dist_m(icoord_mo,0)
                  m = dist_m(icoord_mo,mi)
                  if (l>=m) then
                     dist_mlo(icoord_mo, icoord_lo, k, 1) = m
                     dist_mlo(icoord_mo, icoord_lo, k, 2) = l
                     k = k + 1
                  end if
               end do
            end do
         end do
         deallocate(dist_l)
      end do
      
   end subroutine distribute_mlo_lfirst
   
!    !----------------------------------------------------------------------------   
!    subroutine distribute_mlo_lfirst
!       !
!       !   This loop will now distribute the (m,l) pairs amongst all the 
!       !   rank_mlo. It will make sure that each coord_mo will only keep the 
!       !   (m,l) pairs whose m is in coord_m. This is aimed at reducing 
!       !   communication. It will also follow the number of (m,l) points 
!       !   that we saved in n_mlo input variable.
!       !   
!       !   This subroutine will minimize the number of m's in each coord_r by 
!       !   looping over l first, and then over m while distributing the pairs.
!       !   
!       !   This is probably not what you want. This subroutine is here mostly
!       !   for academic purposes and tests!
!       !
!       !   Author: Rafael Lago, MPCDF, June 2018
!       !
!       integer :: tmp_mlo(0:n_ranks_mo-1, 0:n_ranks_lo-1, lm_max, 2)
!       integer :: icoord_mo, icoord_lo
!       integer :: n_l_array, n_l, l_min, k, mi, lj, n, l, m, n_lj
!       
!       integer, allocatable :: dist_l(:,:)
!       
!       tmp_mlo = -1
!       do icoord_mo=0,n_ranks_mo-1
!          
!          ! Number of l points in icoord_mo
!          l_min = minval(dist_m(icoord_mo, 1:dist_m(icoord_mo,0)))
!          n_l = l_max - l_min + 1
!          n_l_array = ceiling(real(n_l) / real(n_ranks_lo))
!          allocate(dist_l(0:n_ranks_lo-1, 0:n_l_array))
!          dist_l = -1
!          
!          ! Distribute l points with snake ordering
!          call distribute_discontiguous_snake(dist_l, n_l_array, n_l, n_ranks_lo)
!          ! The function above gives numbers from 1:n_l. 
!          ! We want them from l_min:l_min+n_l, but in descending order:
!          dist_l(:,1:) = l_max - (l_min + dist_l(:,1:) - 1) + l_min
!          do icoord_lo=0, n_ranks_lo-1
!             ! Stores mapping in a temporary array
!             k = 1
!             
!             ! Loops lj backwards, otherwise the ls will be arranged backwards
!             ! in memory
!             do lj = dist_l(icoord_lo,0),1,-1
!                l = dist_l(icoord_lo,lj)
!                do mi=1, dist_m(icoord_mo,0)
!                   m = dist_m(icoord_mo,mi)
!                   if (l>=m) then
!                      tmp_mlo(icoord_mo, icoord_lo, k, 1) = m
!                      tmp_mlo(icoord_mo, icoord_lo, k, 2) = l
!                      k = k + 1
!                   end if
!                end do
!             end do
!             
!             ! Stores number of mlo points in this rank_mo/rank_lo
!             dist_n_mlo(icoord_mo, icoord_lo) = k-1
!          end do
!          deallocate(dist_l)
!       end do
!       
!       ! Now that sizes are known, copy from tmp into dist_mlo
!       n_mlo_array = maxval(dist_n_mlo)
!       allocate(dist_mlo(0:n_ranks_mo-1, 0:n_ranks_lo-1, n_mlo_array, 2))
!       dist_mlo = -1
!       do icoord_mo=0,n_ranks_mo-1
!          do icoord_lo=0,n_ranks_lo-1
!             n = dist_n_mlo(icoord_mo,icoord_lo)
!             dist_mlo(icoord_mo, icoord_lo, 1:n, 1:2) = &
!             &   tmp_mlo(icoord_mo, icoord_lo, 1:n, 1:2) 
!          end do
!       end do
!       
!    end subroutine distribute_mlo_lfirst
   
   !----------------------------------------------------------------------------   
   subroutine distribute_mlo_lexicographic
      !
      !   This loop will distribute (m,l) points (for lmloop) with the following
      !   priority:
      !     - fair total number of points between ranks
      !     - minimize the l points in a rank
      !   
      !   This distribution is far from being optimal and should work just as 
      !   a placeholder.
      !   
      !   Author: Rafael Lago, MPCDF, June 2018
      !
      integer :: tmp_cont(0:n_ranks_r-1,0:2)
      integer :: icoord_mo, icoord_lo, irank
      integer :: l, m, mi, i, lm
      integer :: taken(0:m_max, 0:l_max)
      
      dist_n_mlo = 0
      
      !-- Compute how many ml-pairs will be store in each rank
      !
      n_mlo_array = ceiling(real(maxval(dist_n_lm))/real(n_ranks_lo))
      allocate(dist_mlo(0:n_ranks_mo-1, 0:n_ranks_lo-1, n_mlo_array, 2))
      dist_mlo = -1
      
      do icoord_mo=0,n_ranks_m-1
         tmp_cont = 0
         call distribute_contiguous_last(tmp_cont, dist_n_lm(icoord_mo), n_ranks_lo)
         lm=1
         i =1
         icoord_lo=0
         do mi=1,dist_m(icoord_mo,0)
            m = dist_m(icoord_mo,mi)
            do l=m,l_max
               dist_mlo(icoord_mo,icoord_lo,i,1) = m
               dist_mlo(icoord_mo,icoord_lo,i,2) = l
               lm = lm + 1
               i = i + 1
               if (lm>tmp_cont(icoord_lo,2)) then
                  dist_n_mlo(icoord_mo, icoord_lo) = i - 1
                  icoord_lo = icoord_lo + 1
                  i = 1
               end if
            end do
         end do
      end do
      
   end subroutine distribute_mlo_lexicographic
   
   !----------------------------------------------------------------------------
   subroutine check_geometry
      !
      !  This function checks truncations and writes it into STDOUT and the 
      !  log-file.                                 
      !  

      if ( minc < 1 ) then
         call abortRun('! Wave number minc should be > 0!')
      end if
      if ( mod(n_phi_tot,minc) /= 0 .and. (.not. l_axi) ) then
         call abortRun('! Number of longitude grid points n_phi_tot must be a multiple of minc')
      end if
      if ( mod(n_phi_max,4) /= 0 .and. (.not. l_axi) ) then
         call abortRun('! Number of longitude grid points n_phi_tot/minc must be a multiple of 4')
      end if
      if ( mod(n_phi_tot,16) /= 0 .and. (.not. l_axi) ) then
         call abortRun('! Number of longitude grid points n_phi_tot must be a multiple of 16')
      end if
      if ( n_phi_max/2 <= 2 .and. (.not. l_axi) ) then
         call abortRun('! Number of longitude grid points n_phi_tot must be larger than 2*minc')
      end if

      !-- Checking radial grid:
      if ( .not. l_finite_diff ) then
         if ( mod(n_r_max-1,4) /= 0 ) then
            call abortRun('! Number n_r_max-1 should be a multiple of 4')
         end if
      end if

      if ( n_theta_max <= 2 ) then
         call abortRun('! Number of latitude grid points n_theta_max must be larger than 2')
      end if
      if ( mod(n_theta_max,4) /= 0 ) then
         call abortRun('! Number n_theta_max of latitude grid points be a multiple must be a multiple of 4')
      end if
      if ( n_cheb_max > n_r_max ) then
         call abortRun('! n_cheb_max should be <= n_r_max!')
      end if
      if ( n_cheb_max < 1 ) then
         call abortRun('! n_cheb_max should be > 1!')
      end if

   end subroutine check_geometry
   !----------------------------------------------------------------------------   
   subroutine distribute_discontiguous_snake(dist, max_len, N, p)
      !  
      !   Distributes a list of points [x1, x2, ..., xN] amonst p ranks using
      !   snake ordering. The output is just a list containing the indexes
      !   of these points (e.g. [0,7,8,15]).
      !  
      !   max_len is supposed to be the ceiling(N/p)
      !  
      !   Author: Rafael Lago, MPCDF, June 2018
      !  
      integer, intent(in)    :: max_len, N, p
      integer, intent(inout) :: dist(0:p-1, 0:max_len)
      
      integer :: j, ipt, irow
      
      dist(:,:) =  -1
      ipt  = 1
      irow = 1
      
      do while (.TRUE.)
         do j=0, p-1
            dist(j, irow) = ipt
            ipt = ipt + 1
            if (ipt > N) goto 10
         end do
         irow = irow + 1
         do j=p-1,0,-1
            dist(j, irow) = ipt
            ipt = ipt + 1
            if (ipt > N) goto 10
         end do
         irow = irow + 1
      end do
      
      10 continue
      dist(:,0) = count(dist(:,1:) >= 0, 2)

   end subroutine distribute_discontiguous_snake
   !----------------------------------------------------------------------------   
   subroutine distribute_discontiguous_roundrobin(dist, max_len, N, p)
      !  
      !   Distributes a list of points [x1, x2, ..., xN] amonst p ranks using
      !   round robin ordering. The output is just a list containing the indexes
      !   of these points (e.g. [0,4,8,12]).
      !  
      !   max_len is supposed to be the ceiling(N/p)
      !  
      !   Author: Rafael Lago, MPCDF, June 2018
      !  
      integer, intent(in)    :: max_len, N, p
      integer, intent(inout) :: dist(0:p-1, 0:max_len)
      
      integer :: j, ipt, irow
      
      dist(:,:) =  -1
      ipt  = 1
      irow = 1
      
      do while (.TRUE.)
         do j=0, p-1
            dist(j, irow) = ipt
            ipt = ipt + 1
            if (ipt > N) return
         end do
         irow = irow + 1
      end do
   end subroutine distribute_discontiguous_roundrobin
   
   !----------------------------------------------------------------------------
   subroutine distribute_contiguous_first(dist,N,p)
      !  
      !   Distributes a list of points [x1, x2, ..., xN] amonst p ranks such 
      !   that each coord_r receives a "chunk" of points. The output are three 
      !   integers (per coord_r) referring to the number of points, the first 
      !   points and the last point of the chunk (e.g. [4,0,3]).
      !  
      !   If the number of points is not divisible by p, we add one extra point
      !   in the first N-(N/p) ranks (thus, "first")
      !  
      !   Author: Rafael Lago, MPCDF, June 2018
      !  
      integer, intent(in) :: p
      integer, intent(in) :: N
      integer, intent(out) :: dist(0:p-1,0:2)
      
      integer :: rem, loc, i
      
      loc = N/p
      rem = N - loc*p
      do i=0,p-1
         dist(i,1) = loc*i + min(i,rem) + 1
         dist(i,2) = loc*(i+1) + min(i+1,rem)
      end do
   end subroutine distribute_contiguous_first
   !----------------------------------------------------------------------------
   subroutine distribute_contiguous_last(dist,N,p)
      !  
      !   Like distribute_contiguous_first, but extra points go into the 
      !   last N-(N/p) ranks (thus, "last")
      !  
      !   Author: Rafael Lago, MPCDF, June 2018
      !  
      integer, intent(in) :: p
      integer, intent(in) :: N
      integer, intent(out) :: dist(0:p-1,0:2)
      
      integer :: rem, loc, i
      
      loc = N/p
      rem = N - loc*p
      do i=0,p-1
         dist(i,1) = loc*i + max(i+rem-p,0) + 1
         dist(i,2) = loc*(i+1) + max(i+rem+1-p,0)
      end do
   end subroutine distribute_contiguous_last
   
   !----------------------------------------------------------------------------
   subroutine print_contiguous_distribution(dist,p,name)
      !  
      !   Author: Rafael Lago, MPCDF, June 2018
      !  
      integer, intent(in) :: p
      integer, intent(in) :: dist(0:p-1,0:2)
      character(*), intent(in) :: name
      integer :: i
      
      if (.not. l_master_rank) return
      
      write(n_geometry_file,"(' !  Partition in rank_',A,' ', I0, ': ', I0,'-',I0, '  (', I0, ' pts)')") name, &
            0, dist(0,1), dist(0,2), dist(0,0)
            
      do i=1, p-1
         write(n_geometry_file,"(' !               rank_',A,' ', I0, ': ', I0,'-',I0, '  (', I0, ' pts)')") name, &
               i, dist(i,1), dist(i,2), dist(i,0)
      end do
   end subroutine print_contiguous_distribution
   
   !----------------------------------------------------------------------------
   subroutine print_discontiguous_distribution(dist,max_len,p,name)
      !  
      !   Author: Rafael Lago, MPCDF, June 2018
      !  
      integer, intent(in) :: max_len, p
      integer, intent(in) :: dist(0:p-1,0:max_len)
      character(*), intent(in) :: name
      
      integer :: i, j, counter
      
      if (.not. l_master_rank) return
      
      write (n_geometry_file,'(A,I0,A,I0)', ADVANCE='NO') ' !  Partition in rank_'//name//' ', 0, ' :', dist(0,1)
      counter = 1
      do j=2, dist(0,0)
         write (n_geometry_file, '(A,I0)', ADVANCE='NO') ',', dist(0,j)
      end do
      write (n_geometry_file, '(A,I0,A)') "  (",dist(0,0)," pts)"
      
      do i=1, n_ranks_theta-1
         write (n_geometry_file,'(A,I0,A,I0)', ADVANCE='NO') ' !               rank_'//name//' ', i, ' :', dist(i,1)
         counter = 1
         do j=2, dist(i,0)
            write (n_geometry_file, '(A,I0)', ADVANCE='NO') ',', dist(i,j)
         end do
         write (n_geometry_file, '(A,I0,A)') "  (",dist(i,0)," pts)"
      end do
   end subroutine print_discontiguous_distribution
   
   !----------------------------------------------------------------------------
   subroutine print_mlo_distribution
      !   
      !   Because this is a very special kind of distribution, it has its own
      !   print routine
      !   
      !   Author: Rafael Lago, MPCDF, June 2018
      !
      integer :: icoord_mo, icoord_lo, i
      integer :: l, m
      logical :: mfirst, lfirst
      
      if (.not. l_master_rank) return
      
      do icoord_lo=0,n_ranks_lo-1
         write (n_geometry_file,'(A,I0)') ' !   # points in rank_lo ',icoord_lo
         do icoord_mo=0,n_ranks_mo-1
            write (n_geometry_file,'(A,I0,A)', ADVANCE='NO') ' !               rank_mo ',icoord_mo, ' :'
            lfirst = .true.
            do l=0,m_max
               if (.not. any(dist_mlo(icoord_mo,icoord_lo,:,2)==l)) cycle
               if (.not. lfirst) write (n_geometry_file,'(A,I0,A)', ADVANCE='NO') &
               &    ' !                          '
               lfirst = .false.
               write (n_geometry_file,'(A,I0,A)', ADVANCE='NO') ' l=',l,', m=['
               mfirst = .true.
               do i=1,dist_n_mlo(icoord_mo,icoord_lo)
                  if (dist_mlo(icoord_mo,icoord_lo,i,2)/=l) cycle
                  m = dist_mlo(icoord_mo,icoord_lo,i,1)
                  if (mfirst) then
                     write (n_geometry_file,'(I0)', ADVANCE='NO') m
                     mfirst = .false.
                  else
                     write (n_geometry_file,'(A,I0)', ADVANCE='NO') ',',m
                  end if
               end do
               write (n_geometry_file,'(A)', ADVANCE='NO') "]"//NEW_LINE("a")
            end do
         end do
      end do
      
   end subroutine print_mlo_distribution
   
   !----------------------------------------------------------------------------
   subroutine print_mlo_distribution_summary
      !   
      !   Summarized version of print_mlo_distribution
      !   
      !   Author: Rafael Lago, MPCDF, June 2018
      !
      integer :: icoord_mo, icoord_lo, m_count, l_count
      integer :: l, m
      
      if (.not. l_master_rank) return
      
      write (n_geometry_file,'(A,A)') ' !   mlo_dist_method: ', mlo_dist_method
      do icoord_lo=0,n_ranks_lo-1
         write (n_geometry_file,'(A,I0)') ' !   # points in rank_lo ',icoord_lo
         do icoord_mo=0,n_ranks_mo-1
            write (n_geometry_file,'(A,I0,A)', ADVANCE='NO') ' !               rank_mo ',icoord_mo, ' :'
            
            !-- Count how many different l's
            l_count = 0
            do l=0,l_max
               if (any(dist_mlo(icoord_mo,icoord_lo,:,2)==l)) l_count = l_count + 1
            end do
            
            !-- Count how many different m's
            m_count = 0
            do m=0,l_max
               if (any(dist_mlo(icoord_mo,icoord_lo,:,1)==m)) m_count = m_count + 1
            end do
            
            write (n_geometry_file,'(I0,A,I0,A,I0,A)') m_count, " m, ", l_count, " l (", dist_n_mlo(icoord_mo,icoord_lo), " total)"
         end do
      end do
      
   end subroutine print_mlo_distribution_summary
   
!------------------------------------------------------------------------------
   subroutine getBlocks(bal, n_points, n_ranks_r)

      type(load), intent(inout) :: bal(0:)
      integer, intent(in) :: n_ranks_r
      integer, intent(in) :: n_points

      integer :: n_points_loc, check, p

      n_points_loc = n_points/n_ranks_r

      check = mod(n_points,n_ranks_r)!-1

      bal(0)%nStart = 1

      do p =0, n_ranks_r-1
         if ( p /= 0 ) bal(p)%nStart=bal(p-1)%nStop+1
         bal(p)%n_per_rank=n_points_loc
         if ( p == n_ranks_r-1 ) then
            bal(p)%n_per_rank=n_points_loc+check
         end if
         bal(p)%nStop=bal(p)%nStart+bal(p)%n_per_rank-1
      end do

   end subroutine getBlocks
   
!-----------------------------------------------------------------------------
end module truncation
