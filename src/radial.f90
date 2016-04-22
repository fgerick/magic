module radial_functions
   !
   !  This module initiates all the radial functions (transport properties, density,
   !  temperature, cheb transforms, etc.)
   !

   use truncation, only: n_r_max, n_cheb_max, n_r_ic_max
   use matrices, only: s0Mat,s0Pivot
   use algebra, only: sgesl,sgefa
   use constants, only: sq4pi, one, two, three, four, half
   use physical_parameters
   use num_param, only: alpha
   use logic, only: l_mag, l_cond_ic, l_heat, l_anelastic_liquid, &
       &            l_isothermal, l_anel, l_newmap
   use chebyshev_polynoms_mod ! Everything is needed
   use cosine_transform_odd
   use cosine_transform_even
   use radial_der, only: get_dr
   use mem_alloc, only: bytes_allocated
   use useful, only: logWrite
 
   implicit none

   private
 
   !-- arrays depending on r:
   real(cp), public, allocatable :: r(:)         ! radii
   real(cp), public, allocatable :: r_ic(:)      ! IC radii
   real(cp), public, allocatable :: O_r_ic(:)    ! Inverse of IC radii
   real(cp), public, allocatable :: O_r_ic2(:)   ! Inverse of square of IC radii
   real(cp), public, allocatable :: or1(:)       ! :math:`1/r`
   real(cp), public, allocatable :: or2(:)       ! :math:`1/r^2`
   real(cp), public, allocatable :: or3(:)       ! :math:`1/r^3`
   real(cp), public, allocatable :: or4(:)       ! :math:`1/r^4`
   real(cp), public, allocatable :: otemp1(:)    ! Inverse of background temperature
   real(cp), public, allocatable :: rho0(:)      ! Inverse of background density
   real(cp), public, allocatable :: temp0(:)     ! Background temperature
   real(cp), public, allocatable :: dLtemp0(:)   ! Inverse of temperature scale height
   real(cp), public, allocatable :: ddLtemp0(:)  ! :math:`d/dr(1/T dT/dr)` 
   real(cp), private, allocatable :: d2temp0(:)  ! Second rad. derivative of background temperature
   real(cp), public, allocatable :: dentropy0(:) ! Radial gradient of background entropy
   real(cp), public, allocatable :: orho1(:)     ! :math:`1/\tilde{\rho}`
   real(cp), public, allocatable :: orho2(:)     ! :math:`1/\tilde{\rho}^2`
   real(cp), public, allocatable :: beta(:)      ! Inverse of density scale height drho0/rho0
   real(cp), public, allocatable :: dbeta(:)     ! Radial gradient of beta

   real(cp), public, allocatable :: alpha0(:)    ! Thermal expansion coefficient
   real(cp), public, allocatable :: dLalpha0(:)  ! :math:`1/\alpha d\alpha/dr`
   real(cp), public, allocatable :: ddLalpha0(:) ! :math:`d/dr(1/alpha d\alpha/dr)`

   real(cp), public, allocatable :: drx(:)       ! First derivative of non-linear mapping (see Bayliss and Turkel, 1990)
   real(cp), public, allocatable :: ddrx(:)      ! Second derivative of non-linear mapping
   real(cp), public, allocatable :: dddrx(:)     ! Third derivative of non-linear mapping
   real(cp), public :: dr_fac                    ! :math:`2/d`, where :math:`d=r_o-r_i`
   real(cp), public :: dr_fac_ic                 ! For IC: :math:`2/(2 r_i)`
   real(cp), public :: alpha1   ! Input parameter for non-linear map to define degree of spacing (0.0:2.0)
   real(cp), public :: alpha2   ! Input parameter for non-linear map to define central point of different spacing (-1.0:1.0)
   real(cp), public :: r_cmb                     ! OC radius
   real(cp), public :: r_icb                     ! IC radius
   real(cp), public :: r_surface                 ! Surface radius for extrapolation
 
   !-- arrays for buoyancy, depend on Ra and Pr:
   real(cp), public, allocatable :: rgrav(:)     ! Buoyancy term `dtemp0/Di`
   real(cp), public, allocatable :: agrav(:)     ! Buoyancy term `dtemp0/Di*alpha`
 
   !-- chebychev polynomials, derivatives and integral:
   real(cp), public :: cheb_norm                    ! Chebyshev normalisation 
   real(cp), public, allocatable :: cheb(:,:)       ! Chebyshev polynomials
   real(cp), public, allocatable :: dcheb(:,:)      ! First radial derivative
   real(cp), public, allocatable :: d2cheb(:,:)     ! Second radial derivative
   real(cp), public, allocatable :: d3cheb(:,:)     ! Third radial derivative
   real(cp), public, allocatable :: cheb_int(:)     ! Array for cheb integrals
   integer, public :: nDi_costf1                     ! Radii for transform
   integer, public :: nDd_costf1                     ! Radii for transform
   type(costf_odd_t), public :: chebt_oc
   type(costf_odd_t), public :: chebt_ic
   type(costf_even_t), public :: chebt_ic_even
 
   !-- same for inner core:
   real(cp), public :: cheb_norm_ic                      ! Chebyshev normalisation for IC
   real(cp), public, allocatable :: cheb_ic(:,:)         ! Chebyshev polynomials for IC
   real(cp), public, allocatable :: dcheb_ic(:,:)        ! First radial derivative of cheb_ic
   real(cp), public, allocatable :: d2cheb_ic(:,:)       ! Second radial derivative cheb_ic
   real(cp), public, allocatable :: cheb_int_ic(:)       ! Array for integrals of cheb for IC
   integer, public :: nDi_costf1_ic                      ! Radii for transform
 
   integer, public :: nDd_costf1_ic                      ! Radii for transform
 
   integer, public :: nDi_costf2_ic                      ! Radii for transform
 
   integer, public :: nDd_costf2_ic                      ! Radii for transform
 
   !-- Radius functions for cut-back grid without boundaries:
   !-- (and for the nonlinear mapping)
   real(cp), public :: alph1       ! Input parameter for non-linear map to define degree of spacing (0.0:2.0)
   real(cp), public :: alph2       ! Input parameter for non-linear map to define central point of different spacing (-1.0:1.0)
 
   real(cp), public, allocatable :: lambda(:)     ! Array of magnetic diffusivity
   real(cp), public, allocatable :: dLlambda(:)   ! Derivative of magnetic diffusivity
   real(cp), public, allocatable :: jVarCon(:)    ! Analytical solution for toroidal field potential aj (see init_fields.f90)
   real(cp), public, allocatable :: sigma(:)      ! Electrical conductivity
   real(cp), public, allocatable :: kappa(:)      ! Thermal diffusivity
   real(cp), public, allocatable :: dLkappa(:)    ! Derivative of thermal diffusivity
   real(cp), public, allocatable :: visc(:)       ! Kinematic viscosity
   real(cp), public, allocatable :: dLvisc(:)     ! Derivative of kinematic viscosity
   real(cp), public, allocatable :: divKtemp0(:)  ! Term for liquid anelastic approximation
   real(cp), public, allocatable :: epscProf(:)   ! Sources in heat equations

   public :: initialize_radial_functions, radial, transportProperties

contains

   subroutine initialize_radial_functions
      !
      ! Initial memory allocation
      !

      nDi_costf1=2*n_r_max+2
      nDd_costf1=2*n_r_max+5

      nDi_costf1_ic=2*n_r_ic_max+2
      nDd_costf1_ic=2*n_r_ic_max+5
      nDi_costf2_ic=2*n_r_ic_max
      nDd_costf2_ic=2*n_r_ic_max+n_r_ic_max/2+5

      ! allocate the arrays
      allocate( r(n_r_max) )
      allocate( r_ic(n_r_ic_max) )
      allocate( O_r_ic(n_r_ic_max) )
      allocate( O_r_ic2(n_r_ic_max) )
      allocate( or1(n_r_max),or2(n_r_max),or3(n_r_max),or4(n_r_max) )
      allocate( otemp1(n_r_max),rho0(n_r_max),temp0(n_r_max) )
      allocate( dLtemp0(n_r_max),d2temp0(n_r_max),dentropy0(n_r_max) )
      allocate( ddLtemp0(n_r_max) )
      allocate( orho1(n_r_max),orho2(n_r_max) )
      allocate( beta(n_r_max), dbeta(n_r_max) )
      allocate( alpha0(n_r_max), dLalpha0(n_r_max), ddLalpha0(n_r_max) )
      allocate( drx(n_r_max),ddrx(n_r_max),dddrx(n_r_max) )
      allocate( rgrav(n_r_max),agrav(n_r_max) )
      bytes_allocated = bytes_allocated + &
                        (24*n_r_max+3*n_r_ic_max)*SIZEOF_DEF_REAL

      allocate( cheb(n_r_max,n_r_max) )     ! Chebychev polynomials
      allocate( dcheb(n_r_max,n_r_max) )    ! first radial derivative
      allocate( d2cheb(n_r_max,n_r_max) )   ! second radial derivative
      allocate( d3cheb(n_r_max,n_r_max) )   ! third radial derivative
      allocate( cheb_int(n_r_max) )         ! array for cheb integrals !
      bytes_allocated = bytes_allocated + &
                        (4*n_r_max*n_r_max+n_r_max)*SIZEOF_DEF_REAL

      call chebt_oc%initialize(n_r_max,nDi_costf1,nDd_costf1)

      allocate( cheb_ic(n_r_ic_max,n_r_ic_max) )
      allocate( dcheb_ic(n_r_ic_max,n_r_ic_max) )
      allocate( d2cheb_ic(n_r_ic_max,n_r_ic_max) )
      allocate( cheb_int_ic(n_r_ic_max) )
      bytes_allocated = bytes_allocated + &
                        (3*n_r_ic_max*n_r_ic_max+n_r_ic_max)*SIZEOF_DEF_REAL

      call chebt_ic%initialize(n_r_ic_max,nDi_costf1_ic,nDd_costf1_ic)

      allocate( lambda(n_r_max),dLlambda(n_r_max),jVarCon(n_r_max) )
      allocate( sigma(n_r_max) )
      allocate( kappa(n_r_max),dLkappa(n_r_max) )
      allocate( visc(n_r_max),dLvisc(n_r_max) )
      allocate( epscProf(n_r_max),divKtemp0(n_r_max) )
      bytes_allocated = bytes_allocated + 10*n_r_max*SIZEOF_DEF_REAL

   end subroutine initialize_radial_functions
!------------------------------------------------------------------------------
   subroutine radial
      !
      !  Calculates everything needed for radial functions, transforms etc.
      !

      !-- Local variables:
      integer :: n_r,n_cheb,n_cheb_int
      integer :: n_r_ic_tot,k
      integer :: n_const(1)

      !integer :: n_r_start
      real(cp) :: fac_int
      real(cp) :: r_cheb(n_r_max)
      real(cp) :: r_cheb_ic(2*n_r_ic_max-1),r_ic_2(2*n_r_ic_max-1)
      real(cp) :: drho0(n_r_max),dtemp0(n_r_max)
      real(cp) :: lambd,paraK,paraX0 !parameters of the nonlinear mapping

      real(cp) :: hcomp,fac
      real(cp) :: dtemp0cond(n_r_max),dtemp0ad(n_r_max),hcond(n_r_max)
      real(cp) :: func(n_r_max)

      real(cp) :: rStrat
      real(cp), allocatable :: coeffDens(:), coeffTemp(:)
      real(cp) :: w1(n_r_max),w2(n_r_max)
      character(len=80) :: message

#if 0
      integer :: filehandle
#endif

      !-- Radial grid point:
      !   radratio is aspect ratio
      !   radratio = (inner core r) / (CMB r) = r_icb/r_cmb
      r_cmb=one/(one-radratio)
      r_icb=r_cmb-one
      r_surface=2.8209_cp    ! in units of (r_cmb-r_icb)

      cheb_norm=sqrt(two/real(n_r_max-1,kind=cp))
      dr_fac=two/(r_cmb-r_icb)

      if ( l_newmap ) then
         alpha1         =alph1
         alpha2         =alph2
         paraK=atan(alpha1*(1+alpha2))/atan(alpha1*(1-alpha2))
         paraX0=(paraK-1)/(paraK+1)
         lambd=atan(alpha1*(1-alpha2))/(1-paraX0)
      else
         alpha1         =0.0_cp
         alpha2         =0.0_cp
      end if

      !-- Start with outer core:
      !   cheb_grid calculates the n_r_max gridpoints, these
      !   are the extrema of a Cheb pylonomial of degree n_r_max-1,
      !   r_cheb are the grid_points in the Cheb interval [-1,1]
      !   and r are these points mapped to the interval [r_icb,r_cmb]:
      call cheb_grid(r_icb,r_cmb,n_r_max-1,r,r_cheb, &
                           alpha1,alpha2,paraX0,lambd)
#if 0
      do n_r=1,n_r_max
         write(*,"(I3,2ES20.12)") n_r,r_cheb(n_r),r(n_r)
      end do
#endif

      if ( l_newmap ) then
         do n_r=1,n_r_max
            drx(n_r) =                          (two*alpha1) /      &
                 ((one+alpha1**2*(two*r(n_r)-r_icb-r_cmb-alpha2)**2)* &
                 lambd)
            ddrx(n_r) = -(8.0_cp*alpha1**3*(two*r(n_r)-r_icb-r_cmb-alpha2)) / &
                 ((one+alpha1**2*(-two*r(n_r)+r_icb+r_cmb+alpha2)**2)**2*  & 
                 lambd)
            dddrx(n_r) =        (16.0_cp*alpha1**3*(-one+three*alpha1**2* &
                                  (-two*r(n_r)+r_icb+r_cmb+alpha2)**2)) / &
                 ((one+alpha1**2*(-two*r(n_r)+r_icb+r_cmb+alpha2)**2)**3* &
                 lambd)
         end do
      else
         do n_r=1,n_r_max
            drx(n_r)=two/(r_cmb-r_icb)
            ddrx(n_r)=0
            dddrx(n_r)=0
         end do
      end if

      !-- Calculate chebs and their derivatives up to degree n_r_max-1
      !   on the n_r radial grid points r:
      call get_chebs(n_r_max,r_icb,r_cmb,r_cheb,n_r_max,       &
                     cheb,dcheb,d2cheb,d3cheb,n_r_max,n_r_max, &
                     drx,ddrx,dddrx)

#if 0
      open(newuniT=filehandle,file="r_cheb.dat")
      do n_r=1,n_r_max
         write(filehandle,"(2ES20.12)") r_cheb(n_r),r(n_r)
      end do
      close(filehandle)
#endif

      or1=one/r         ! 1/r
      or2=or1*or1       ! 1/r**2
      or3=or1*or2       ! 1/r**3
      or4=or2*or2       ! 1/r**4

      !-- Fit to an interior model
      if ( index(interior_model,'JUP') /= 0 ) then

         coeffDens = [4.46020423_cp, -4.60312999_cp, 37.38863965_cp,       &
            &         -201.96655354_cp, 491.00495215_cp, -644.82401602_cp, &
            &         440.86067831_cp, -122.36071577_cp] 

         coeffTemp = [0.999735638_cp, 0.0111053831_cp, 2.70889691_cp,  &
            &         -83.5604443_cp, 573.151526_cp, -1959.41844_cp,   &
            &         3774.39367_cp, -4159.56327_cp, 2447.75300_cp,    &
            &         -596.464198_cp]

         call polynomialBackground(coeffDens,coeffTemp)

      else if ( index(interior_model,'SAT') /= 0 ) then

         ! the shell can't be thicker than eta=0.15, because the fit doesn't 
         ! work below that (in Nadine's profile, that's where the IC is anyway)
         ! also r_cut_model maximum is 0.999, because rho is negative beyond
         ! that

         coeffDens = [-0.33233543_cp, 0.90904075_cp, -0.9265371_cp, &
                      0.34973134_cp ]

         coeffTemp = [1.00294605_cp,-0.44357815_cp,13.9295826_cp,  &
            &         -137.051347_cp,521.181670_cp,-1044.41528_cp, &
            &         1166.04926_cp,-683.198387_cp, 162.962632_cp ]

         call polynomialBackground(coeffDens,coeffTemp)


      else if ( index(interior_model,'SUN') /= 0 ) then

         ! rho is negative beyond r_cut_model=0.9965
         ! radratio should be 0.7 (size of the Sun's CZ)

         coeffDens = [-24.83750402_cp, 231.79029994_cp, -681.72774358_cp, &
            &         918.30741266_cp,-594.30093367_cp, 150.76802942_cp ]

         coeffTemp = [5.53715416_cp, -8.10611274_cp, 1.7350452_cp, &
            &         0.83470843_cp]

         call polynomialBackground(coeffDens,coeffTemp)

      else if ( index(interior_model,'GLIESE229B') /= 0 ) then
         ! Use also nVarDiff=2 with difExp=0.52

         coeffDens = [0.99879163_cp,0.15074601_cp,-4.20328423_cp,   &
            &         6.43542034_cp,-12.67297113_cp,21.68593078_cp, &
            &         -17.74832309_cp,5.35405134_cp]

         coeffTemp = [0.99784506_cp,0.16540448_cp,-3.44594354_cp,   &
            &         3.68189750_cp,-1.39046384_cp]

         call polynomialBackground(coeffDens,coeffTemp)

      else if ( index(interior_model,'COROT3B') /= 0 ) then
         ! Use also nVarDiff=2 with difExp=0.62

         coeffDens = [1.00035987_cp,-0.01294658_cp,-2.78586315_cp,  &
            &         0.70289860_cp,2.59463562_cp,-1.65868190_cp,   &
            &         0.15984718_cp]

         coeffTemp = [1.00299303_cp,-0.33722671_cp,1.71340063_cp,     & 
            &         -12.50287121_cp,21.52708693_cp,-14.91959338_cp, &
            &         3.52970611_cp]

         call polynomialBackground(coeffDens,coeffTemp)

      else if ( index(interior_model,'KOI889B') /= 0 ) then
         ! Use also nVarDiff=2 with difExp=0.68

         coeffDens = [1.01038678_cp,-0.17615484_cp,-1.50567127_cp,  &
            &         -1.65738032_cp,4.20394427_cp,-1.87394994_cp]

         coeffTemp = [1.02100249_cp,-0.60750867_cp,3.23371939_cp,   &
            &         -12.80774142_cp,15.37629271_cp,-6.19288785_cp]

         call polynomialBackground(coeffDens,coeffTemp)

      else if ( index(interior_model,'EARTH') /= 0 ) then
         DissNb =0.3929_cp ! Di = \alpha_O g d / c_p
         ThExpNb=0.0566_cp ! Co = \alpha_O T_O
         GrunNb =1.5_cp ! Gruneisen paramater
         hcomp  =2.2_cp*r_cmb

         alpha0=(one+0.6_cp*r**2/hcomp**2)/(one+0.6_cp/2.2_cp**2)
         rgrav =(r-0.6_cp*r**3/hcomp**2)/(r_cmb*(one-0.6_cp/2.2_cp**2))

         !dentropy0 = -half*(ampStrat+one)*(one-tanh(slopeStrat*(r-rStrat)))+ &
         !            & ampStrat

         !! d ln(temp0) / dr
         !dtemp0=epsS*dentropy0-DissNb*alpha0*rgrav

         !call getBackground(dtemp0,0.0_cp,temp0)
         !temp0=exp(temp0) ! this was ln(T_0)
         !dtemp0=dtemp0*temp0

         !drho0=-ThExpNb*epsS*alpha0*temp0*dentropy0-DissNb/GrunNb*alpha0*rgrav
         !call getBackground(drho0,0.0_cp,rho0)
         !rho0=exp(rho0) ! this was ln(rho_0)
         !beta=drho0

         hcond = (one-0.4469_cp*(r/r_cmb)**2)/(one-0.4469_cp)
         hcond = hcond/hcond(1)
         temp0 = (one+GrunNb*(r_icb**2-r**2)/hcomp**2)
         temp0 = temp0/temp0(1)
         dtemp0cond=-cmbHflux/(r**2*hcond)
          
         do k=1,10 ! 10 iterations is enough to converge
            dtemp0ad=-DissNb*alpha0*rgrav*temp0-epsS*temp0(n_r_max)
            n_const=minloc(abs(dtemp0ad-dtemp0cond))
            rStrat=r(n_const(1))
            func=half*(tanh(slopeStrat*(r-rStrat))+one)

            if ( rStrat<r_cmb ) then
               dtemp0=func*dtemp0cond+(one-func)*dtemp0ad
            else
               dtemp0=dtemp0ad
            end if

            call getBackground(dtemp0,one,temp0)
         end do

         dentropy0=dtemp0/temp0/epsS+DissNb*alpha0*rgrav/epsS
         drho0=-ThExpNb*epsS*alpha0*temp0*dentropy0-DissNb*alpha0*rgrav/GrunNb
         call getBackground(drho0,0.0_cp,rho0)
         rho0=exp(rho0) ! this was ln(rho_0)
         beta=drho0

         ! The final stuff is always required
         call get_dr(beta,dbeta,n_r_max,n_cheb_max,w1,     &
                &    w2,chebt_oc,drx)
         call get_dr(dtemp0,d2temp0,n_r_max,n_cheb_max,w1, &
                &    w2,chebt_oc,drx)
         call get_dr(alpha0,dLalpha0,n_r_max,n_cheb_max,w1, &
                &    w2,chebt_oc,drx)
         dLalpha0=dLalpha0/alpha0 ! d log (alpha) / dr
         call get_dr(dLalpha0,ddLalpha0,n_r_max,n_cheb_max,w1, &
                &    w2,chebt_oc,drx)
         dLtemp0 = dtemp0/temp0
         call get_dr(dLtemp0,ddLtemp0,n_r_max,n_cheb_max,w1, &
                &    w2,chebt_oc,drx)

         ! N.B. rgrav is not gravity but alpha * grav
         rgrav = BuoFac*alpha0*rgrav

      else  !-- Usual polytropic reference state
         ! g(r) = g0 + g1*r/ro + g2*(ro/r)**2
         ! Default values: g0=0, g1=1, g2=0
         ! An easy way to change gravity
         rgrav=BuoFac*(g0+g1*r/r_cmb+g2*(r_cmb/r)**2)
         dentropy0=0.0_cp

         if (l_anel) then
            if (l_isothermal) then ! Gruneisen is zero in this limit
               fac      =strat /( g0+half*g1*(one+radratio) +g2/radratio )
               DissNb   =0.0_cp
               GrunNb   =0.0_cp
               temp0    =one
               rho0     =exp(-fac*(g0*(r-r_cmb) +      &
                         g1/(two*r_cmb)*(r**2-r_cmb**2) - &
                         g2*(r_cmb**2/r-r_cmb)))

               beta     =-fac*rgrav/BuoFac
               dbeta    =-fac*(g1/r_cmb-two*g2*r_cmb**2*or3)
               d2temp0  =0.0_cp
               dLtemp0  =0.0_cp
               ddLtemp0 =0.0_cp
               alpha0   =one/temp0
               dLalpha0 =0.0_cp
               ddLalpha0=0.0_cp
            else
               if ( strat == 0.0_cp .and. DissNb /= 0.0_cp ) then
                  strat = polind* log(( g0+half*g1*(one+radratio)+g2/radratio )* &
                                      DissNb+1)
               else
                  DissNb=( exp(strat/polind)-one )/ &
                         ( g0+half*g1*(one+radratio) +g2/radratio )
               end if
               GrunNb   =one/polind
               temp0    =-DissNb*( g0*r+half*g1*r**2/r_cmb-g2*r_cmb**2/r ) + &
                         one + DissNb*r_cmb*(g0+half*g1-g2)
               rho0     =temp0**polind

               !-- Computation of beta= dln rho0 /dr and dbeta=dbeta/dr
               beta     =-polind*DissNb*rgrav/temp0/BuoFac
               dbeta    =-polind*DissNb/temp0**2 *         &
                         ((g1/r_cmb-two*g2*r_cmb**2*or3)*  &
                         temp0  + DissNb*rgrav**2/BuoFac**2)
               dtemp0   =-DissNb*rgrav/BuoFac
               d2temp0  =-DissNb*(g1/r_cmb-two*g2*r_cmb**2*or3)

               !-- Thermal expansion coefficient (1/T for an ideal gas)
               alpha0   =one/temp0
               dLtemp0  =dtemp0/temp0
               ddLtemp0 =-(dtemp0/temp0)**2+d2temp0/temp0
               dLalpha0 =-dLtemp0
               ddLalpha0=-ddLtemp0
            end if
         end if
      end if

      agrav=alpha*rgrav

      if ( .not. l_heat ) then
         rgrav=0.0_cp
         agrav=0.0_cp
      end if

      if ( l_anel ) then
         call logWrite('')
         call logWrite('!      This is an anelastic model')
         call logWrite('! The key parameters are the following')
         write(message,'(''!      DissNb ='',ES16.6)') DissNb
         call logWrite(message)
         write(message,'(''!      ThExpNb='',ES16.6)') ThExpNb
         call logWrite(message)
         write(message,'(''!      GrunNb ='',ES16.6)') GrunNb
         call logWrite(message)
         write(message,'(''!      N_rho  ='',ES16.6)') strat
         call logWrite(message)
         write(message,'(''!      pol_ind='',ES16.6)') polind
         call logWrite(message)
         call logWrite('')
      end if

      !-- Get additional functions of r:
      if ( l_anel ) then
         orho1      =one/rho0
         orho2      =orho1*orho1
         otemp1     =one/temp0
         ViscHeatFac=DissNb*pr/raScaled
         if (l_mag) then
            OhmLossFac=ViscHeatFac/(ekScaled*prmag**2)
         else
            OhmLossFac=0.0_cp
         end if
      else
         rho0     =one
         temp0    =one
         otemp1   =one
         orho1    =one
         orho2    =one
         alpha0   =one
         beta     =0.0_cp
         dbeta    =0.0_cp
         dLalpha0 =0.0_cp
         ddLalpha0=0.0_cp
         dLtemp0  =0.0_cp
         ddLtemp0 =0.0_cp
         d2temp0  =0.0_cp
         dentropy0=0.0_cp
         ViscHeatFac=0.0_cp
         OhmLossFac =0.0_cp
      end if

      !-- Factors for cheb integrals:
      cheb_int(1)=one   ! Integration constant chosen !
      do n_cheb=3,n_r_max,2
         cheb_int(n_cheb)  =-one/real(n_cheb*(n_cheb-2),kind=cp)
         cheb_int(n_cheb-1)= 0.0_cp
      end do


      !-- Proceed with inner core:

      if ( n_r_ic_max > 0 ) then

         n_r_ic_tot=2*n_r_ic_max-1

         !----- cheb_grid calculates the n_r_ic_tot gridpoints,
         !      these are the extrema of a Cheb of degree n_r_ic_tot-1.
         call cheb_grid(-r_icb,r_icb,n_r_ic_tot-1, &
                         r_ic_2,r_cheb_ic,0.0_cp,0.0_cp,0.0_cp,0.0_cp)

         !----- Store first n_r_ic_max points of r_ic_2 to r_ic:
         do n_r=1,n_r_ic_max-1
            r_ic(n_r)   =r_ic_2(n_r)
            O_r_ic(n_r) =one/r_ic(n_r)
            O_r_ic2(n_r)=O_r_ic(n_r)*O_r_ic(n_r)
         end do
         n_r=n_r_ic_max
         r_ic(n_r)   =0.0_cp
         O_r_ic(n_r) =0.0_cp
         O_r_ic2(n_r)=0.0_cp

         !-- Get no of point on graphical output grid:
         !   No is set to -1 to indicate that point is not on graphical output grid.

      end if

      if ( n_r_ic_max > 0 .and. l_cond_ic ) then

         dr_fac_ic=two/(two*r_icb)
         cheb_norm_ic=sqrt(two/real(n_r_ic_max-1,kind=cp))

         !----- Calculate the even Chebs and their derivative:
         !      n_r_ic_max even chebs up to degree 2*n_r_ic_max-2
         !      at the n_r_ic_max first points in r_ic [r_icb,0].
         !      NOTE invers order in r_ic!
         call get_chebs_even(n_r_ic_max,-r_icb,r_icb,r_cheb_ic, &
                                   n_r_ic_max,cheb_ic,dcheb_ic, &
                                d2cheb_ic,n_r_ic_max,n_r_ic_max)

         !----- Initialize transforms:
         call chebt_ic_even%initialize(n_r_ic_max-1,nDi_costf2_ic,nDd_costf2_ic)

         !----- Factors for cheb integrals, only even contribution:
         fac_int=one/dr_fac_ic   ! thats 1 for the outer core
         cheb_int_ic(1)=fac_int   ! Integration constant chosen !
         do n_cheb=2,n_r_ic_max
            n_cheb_int=2*n_cheb-1
            cheb_int_ic(n_cheb)=-fac_int / real(n_cheb_int*(n_cheb_int-2),kind=cp)
         end do

      end if

   end subroutine radial
!------------------------------------------------------------------------------
   subroutine transportProperties
      !
      ! Calculates the transport properties: electrical conductivity,
      ! kinematic viscosity and thermal conductivity.
      !

      integer :: n_r

      real(cp) :: a,b,c,s1,s2,r0
      real(cp) :: dsigma0
      real(cp) :: dvisc(n_r_max), dkappa(n_r_max), dsigma(n_r_max)
      !real(cp) :: condBot(n_r_max), condTop(n_r_max)
      !real(cp) :: func(n_r_max)
      real(cp) :: kcond(n_r_max)
      real(cp) :: a0,a1,a2,a3,a4,a5
      real(cp) :: kappatop,rrOcmb
      real(cp) :: w1(n_r_max),w2(n_r_max)

      !-- Variable conductivity:

      if ( imagcon == -10 ) then
         nVarCond=1
         lambda  =r**5.0_cp
         sigma   =one/lambda
         dLlambda=5.0_cp/r
      else if ( l_mag ) then
          if ( nVarCond == 0 ) then
             lambda  =one
             sigma   =one
             dLlambda=0.0_cp
          else if ( nVarCond == 1 ) then
             b =log(three)/con_FuncWidth
             r0=con_radratio*r_cmb
             s1=tanh(b*(r0-r_cmb))
             s2=tanh(b*(r0-r_icb))
             a =(-one+con_LambdaOut)/(s1-s2)
             c =(s1-s2*con_LambdaOut)/(s1-s2)
             sigma   = a*tanh(b*(r0-r))+c
             dsigma  =-a*b/cosh(b*(r0-r))
             lambda  =one/sigma
             dLlambda=-dsigma/sigma
          else if ( nVarCond == 2 ) then

             r0=con_radratio*r_cmb
             !------ Use grid point closest to r0:
             do n_r=1,n_r_max
                if ( r(n_r) < r0 )then
                   r0=r(n_r)
                   exit
                end if
             end do
             dsigma0=(con_LambdaMatch-1)*con_DecRate /(r0-r_icb)
             do n_r=1,n_r_max
                if ( r(n_r) < r0 ) then
                   sigma(n_r)   = one+(con_LambdaMatch-1)* &
                       ( (r(n_r)-r_icb)/(r0-r_icb) )**con_DecRate
                   dsigma(n_r)  =  dsigma0 * &
                       ( (r(n_r)-r_icb)/(r0-r_icb) )**(con_DecRate-1)
                else
                   sigma(n_r)  =con_LambdaMatch * &
                       exp(dsigma0/con_LambdaMatch*(r(n_r)-r0))
                   dsigma(n_r) = dsigma0* &
                       exp(dsigma0/con_LambdaMatch*(r(n_r)-r0))
                end if
                lambda(n_r)  = one/sigma(n_r)
                dLlambda(n_r)=-dsigma(n_r)/sigma(n_r)
             end do
          else if ( nVarCond == 3 ) then ! Magnetic diff propto 1/rho
             lambda=rho0(n_r_max)/rho0
             sigma=one/lambda
             call get_dr(lambda,dsigma,n_r_max,n_cheb_max, &
                         w1,w2,chebt_oc,drx)
             dLlambda=dsigma/lambda
          else if ( nVarCond == 4 ) then ! Profile
             lambda=(rho0/rho0(n_r_max))**difExp
             sigma=one/lambda
             call get_dr(lambda,dsigma,n_r_max,n_cheb_max, &
                         w1,w2,chebt_oc,drx)
             dLlambda=dsigma/lambda
          end if
      end if

      !-- Variable thermal diffusivity
      if ( l_heat ) then
         if ( nVarDiff == 0 ) then
            kappa  =one
            dLkappa=0.0_cp
         else if ( nVarDiff == 1 ) then ! Constant conductivity
            ! kappa(n_r)=one/rho0(n_r) Denise's version
            kappa=rho0(n_r_max)/rho0
            call get_dr(kappa,dkappa,n_r_max,n_cheb_max, &
                        w1,w2,chebt_oc,drx)
            dLkappa=dkappa/kappa
         else if ( nVarDiff == 2 ) then ! Profile
            kappa=(rho0/rho0(n_r_max))**difExp
            call get_dr(kappa,dkappa,n_r_max,n_cheb_max, &
                        w1,w2,chebt_oc,drx)
            dLkappa=dkappa/kappa
         else if ( nVarDiff == 3 ) then ! polynomial fit to a model
            if ( radratio < 0.19_cp ) then
               write(*,*) '! NOTE: with this polynomial fit     '
               write(*,*) '! for variable thermal conductivity  '
               write(*,*) '! considering radratio < 0.2 may lead'
               write(*,*) '! to strange profiles'
               stop
            end if
            a0 = -0.32839722_cp
            a1 =  one
            a2 = -1.16153274_cp
            a3 =  0.63741485_cp
            a4 = -0.15812944_cp
            a5 =  0.01034262_cp
            do n_r=1,n_r_max
               rrOcmb = r(n_r)/r_cmb*r_cut_model
               kappa(n_r)= a5 + a4*rrOcmb    + a3*rrOcmb**2 &
                              + a2*rrOcmb**3 + a1*rrOcmb**4 &
                                             + a0*rrOcmb**5

            end do
            kappatop=kappa(1) ! normalise by the value at the top
            kappa=kappa/kappatop
            call get_dr(kappa,dkappa,n_r_max,n_cheb_max, &
                        w1,w2,chebt_oc,drx)
            dLkappa=dkappa/kappa
         else if ( nVarDiff == 4) then ! Earth case
            !condTop=r_cmb**2*dtemp0(1)*or2/dtemp0
            !do n_r=2,n_r_max
            !  if ( r(n_r-1)>rStrat .and. r(n_r)<=rStrat ) then
            !     if ( r(n_r-1)-rStrat < rStrat-r(n_r) ) then
            !        n_const=n_r-1
            !     else
            !        n_const=n_r
            !     end if
            !  end if
            !end do
            !condBot=(rho0/rho0(n_const))*condTop(n_const)
            !func=half*(tanh(slopeStrat*(r-rStrat))+one)
            !kcond=condTop*func+condBot*(1-func)
            !kcond=kcond/kcond(n_r_max)
            !kappa=kcond/rho0
            !call get_dr(kappa,dkappa,n_r_max,n_cheb_max, &
            !            w1,w2,chebt_oc,drx)
            !dLkappa=dkappa/kappa

            ! Alternative scenario
            kcond=(one-0.4469_cp*(r/r_cmb)**2)/(one-0.4469_cp)
            kcond=kcond/kcond(1)
            kappa=kcond/rho0
            call get_dr(kappa,dkappa,n_r_max,n_cheb_max, &
                        w1,w2,chebt_oc,drx)
            dLkappa=dkappa/kappa
         end if
      end if

      !-- Eps profiles
      !-- The remaining division by rho will happen in s_updateS.F90
      if ( nVarEps == 0 ) then
         ! eps is constant
         if ( l_anelastic_liquid ) then
            epscProf(:)=one
         else
            epscProf(:)=otemp1(:)
         end if
      else if ( nVarEps == 1 ) then
         ! rho*eps in the RHS
         if ( l_anelastic_liquid ) then
            epscProf(:)=rho0(:)
         else
            epscProf(:)=rho0(:)*otemp1(:)
         end if
      end if

      !-- Variable viscosity
      if ( nVarVisc == 0 ) then ! default: constant kinematic viscosity
         visc  =one
         dLvisc=0.0_cp
      else if ( nVarVisc == 1 ) then ! Constant dynamic viscosity
         visc=rho0(n_r_max)/rho0
         call get_dr(visc,dvisc,n_r_max,n_cheb_max, &
                     w1,w2,chebt_oc,drx)
         dLvisc=dvisc/visc
      else if ( nVarVisc == 2 ) then ! Profile
         visc=(rho0/rho0(n_r_max))**difExp
         call get_dr(visc,dvisc,n_r_max,n_cheb_max, &
                     w1,w2,chebt_oc,drx)
         dLvisc=dvisc/visc
      end if

      if ( l_anelastic_liquid ) then
         divKtemp0=rho0*kappa*(d2temp0+(beta+dLkappa+two*or1)*temp0*dLtemp0)*sq4pi
      else
         divKtemp0=0.0_cp
      end if

   end subroutine transportProperties
!------------------------------------------------------------------------------
   subroutine getBackground(input,boundaryVal,output)
      !
      ! Linear solver of the form: df/dx = input with f(1)=boundaryVal
      ! 

      !-- Input variables:
      real(cp), intent(in) :: input(n_r_max)
      real(cp), intent(in) :: boundaryVal

      !-- Output variables:
      real(cp), intent(out) :: output(n_r_max)

      !-- Local variables:
      real(cp) :: rhs(n_r_max)
      real(cp) :: tmp(n_r_max)
      integer :: n_cheb,n_r,info


      do n_cheb=1,n_r_max
         do n_r=2,n_r_max
            s0Mat(n_r,n_cheb)=cheb_norm*dcheb(n_cheb,n_r)
         end do
      end do

      !-- boundary conditions
      do n_cheb=1,n_cheb_max
         s0Mat(1,n_cheb)=cheb_norm
         s0Mat(n_r_max,n_cheb)=0.0_cp
      end do

      !-- fill with zeros
      if ( n_cheb_max < n_r_max ) then
         do n_cheb=n_cheb_max+1,n_r_max
            s0Mat(1,n_cheb)=0.0_cp
         end do
      end if

      !-- renormalize
      do n_r=1,n_r_max
         s0Mat(n_r,1)      =half*s0Mat(n_r,1)
         s0Mat(n_r,n_r_max)=half*s0Mat(n_r,n_r_max)
      end do

      call sgefa(s0Mat,n_r_max,n_r_max,s0Pivot,info)

      if ( info /= 0 ) then
         write(*,*) '! Singular Matrix in getBackground!'
         stop '20'
      end if

      do n_r=2,n_r_max
         rhs(n_r)=input(n_r)
      end do
      rhs(1)=boundaryVal

      !-- Solve for s0:
      call sgesl(s0Mat,n_r_max,n_r_max,s0Pivot,rhs)

      !-- Copy result to s0:
      do n_r=1,n_r_max
         output(n_r)=rhs(n_r)
      end do

      !-- Set cheb-modes > n_cheb_max to zero:
      if ( n_cheb_max < n_r_max ) then
         do n_cheb=n_cheb_max+1,n_r_max
            output(n_cheb)=0.0_cp
         end do
      end if

      !-- Transform to radial space:
      call chebt_oc%costf1(output,tmp)

   end subroutine getBackground
!------------------------------------------------------------------------------
   subroutine polynomialBackground(coeffDens,coeffTemp)
      !
      ! This subroutine allows to calculate a reference state based on an input
      ! polynomial function.
      !

      !-- Input variables
      real(cp), intent(in) :: coeffDens(:)
      real(cp), intent(in) :: coeffTemp(:)

      !-- Local variables
      real(cp) :: rrOcmb(n_r_max),gravFit(n_r_max)
      real(cp) :: drho0(n_r_max),dtemp0(n_r_max)
      real(cp) :: w1(n_r_max),w2(n_r_max)

      integer ::  nDens,nTemp,i

      nDens = size(coeffDens)
      nTemp = size(coeffTemp)
      rrOcmb(:) = r(:)*r_cut_model/r_cmb
      gravFit(:)=four*rrOcmb(:)-three*rrOcmb(:)**2

      ! Set to zero initially
      rho0(:) =0.0_cp
      temp0(:)=0.0_cp

      do i=1,nDens
         rho0(:) = rho0(:)+coeffDens(i)*rrOcmb(:)**(i-1)
      end do

      do i=1,nTemp
         temp0(:) = temp0(:)+coeffTemp(i)*rrOcmb(:)**(i-1)
      end do
      
      ! Normalise to the outer radius
      temp0  =temp0/temp0(1)
      rho0   =rho0/rho0(1)
      gravFit=gravFit/gravFit(1)

      ! Derivative of the temperature needed to get alpha_T
      call get_dr(temp0,dtemp0,n_r_max,n_cheb_max,w1, &
                  w2,chebt_oc,drx)

      alpha0=-dtemp0/(gravFit*temp0)

      ! Dissipation number
      DissNb=alpha0(1)
      alpha0=alpha0/alpha0(1)

      ! Adiabatic: buoyancy term is linked to the temperature gradient

      !       dT
      !      ---- =  -Di * alpha_T * T * grav
      !       dr
      rgrav=-BuoFac*dtemp0/DissNb

      call get_dr(rho0,drho0,n_r_max,n_cheb_max,w1, &
             &    w2,chebt_oc,drx)
      beta=drho0/rho0
      call get_dr(beta,dbeta,n_r_max,n_cheb_max,w1,     &
             &     w2,chebt_oc,drx)
      call get_dr(dtemp0,d2temp0,n_r_max,n_cheb_max,w1, &
             &  w2,chebt_oc,drx)
      call get_dr(alpha0,dLalpha0,n_r_max,n_cheb_max,w1, &
             &    w2,chebt_oc,drx)
      dLalpha0=dLalpha0/alpha0 ! d log (alpha) / dr
      call get_dr(dLalpha0,ddLalpha0,n_r_max,n_cheb_max,w1, &
             &    w2,chebt_oc,drx)
      dLtemp0 = dtemp0/temp0
      call get_dr(dLtemp0,ddLtemp0,n_r_max,n_cheb_max,w1, &
             &    w2,chebt_oc,drx)
      dentropy0(:)=0.0_cp

   end subroutine polynomialBackground
!------------------------------------------------------------------------------
end module radial_functions
