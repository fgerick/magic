!#define DEFAULT
module rIter_batched_mod
   !
   ! This module actually handles the loop over the radial levels. It contains
   ! the spherical harmonic transforms and the operations on the arrays in
   ! physical space.
   !

#ifdef WITHOMP
   use omp_lib
#endif
   use precision_mod
   use num_param, only: phy2lm_counter, lm2phy_counter, nl_counter, &
       &                td_counter
   use parallel_mod
   use blocking, only: st_map
   use horizontal_data, only: O_sin_theta_E2, dLh
#ifdef WITH_OMP_GPU
   use truncation, only: lmP_max, n_phi_max, lm_max, lm_maxMag, n_theta_max, nlat_padded
#else
   use truncation, only: lmP_max, n_phi_max, lm_max, lm_maxMag, n_theta_max
#endif
   use grid_blocking, only: n_phys_space, n_spec_space_lmP, spat2rad, &
       &                    radlatlon2spat
   use logic, only: l_mag, l_conv, l_mag_kin, l_heat, l_ht, l_anel,  &
       &            l_mag_LF, l_conv_nl, l_mag_nl, l_b_nl_cmb,       &
       &            l_b_nl_icb, l_rot_ic, l_cond_ic, l_rot_ma,       &
       &            l_cond_ma, l_dtB, l_store_frame, l_movie_oc,     &
       &            l_TO, l_chemical_conv, l_probe, l_full_sphere,   &
       &            l_precession, l_centrifuge, l_adv_curl,          &
       &            l_double_curl, l_parallel_solve, l_single_matrix,&
       &            l_temperature_diff, l_RMS, l_phase_field, l_onset
   use radial_data, only: n_r_cmb, n_r_icb, nRstart, nRstop, nRstartMag, &
       &                  nRstopMag
   use radial_functions, only: or2, orho1, l_R
   use constants, only: zero, ci
   use nonlinear_lm_mod, only: nonlinear_lm_t
   use grid_space_arrays_3d_mod, only: grid_space_arrays_3d_t
   use TO_arrays_mod, only: TO_arrays_t
   use dtB_arrays_mod, only: dtB_arrays_t
   use torsional_oscillations, only: prep_TO_axi, getTO, getTOnext, getTOfinish
#ifdef WITH_MPI
   use graphOut_mod, only: graphOut_mpi, graphOut_mpi_header
#else
   use graphOut_mod, only: graphOut, graphOut_header
#endif
   use dtB_mod, only: get_dtBLM, get_dH_dtBLM
   use out_movie, only: store_movie_frame
   use outRot, only: get_lorentz_torque
   use courant_mod, only: courant_batch
#ifdef WITH_OMP_GPU
   use nonlinear_bcs, only: get_br_v_bcs, v_rigid_boundary, v_rigid_boundary_batch
#else
   use nonlinear_bcs, only: get_br_v_bcs, v_rigid_boundary
#endif
   use power, only: get_visc_heat
   use outMisc_mod, only: get_ekin_solid_liquid, get_hemi, get_helicity
   use outPar_mod, only: get_fluxes, get_nlBlayers, get_perpPar
   use geos, only: calcGeos
   use sht
   use fields, only: s_Rloc, ds_Rloc, z_Rloc, dz_Rloc, p_Rloc,    &
       &             b_Rloc, db_Rloc, ddb_Rloc, aj_Rloc,dj_Rloc,  &
       &             w_Rloc, dw_Rloc, ddw_Rloc, xi_Rloc, omega_ic,&
       &             omega_ma, dp_Rloc, phi_Rloc
   use time_schemes, only: type_tscheme
   use physical_parameters, only: ktops, kbots, n_r_LCR, ktopv, kbotv
   use rIteration, only: rIter_t
#ifdef WITH_OMP_GPU
   use RMS, only: get_nl_RMS, transform_to_lm_RMS, compute_lm_forces,       &
       &          transform_to_grid_RMS_batch, dtVrLM, dtVtLM, dtVpLM, dpkindrLM, &
       &          Advt2LM, Advp2LM, PFt2LM, PFp2LM, LFrLM, LFt2LM, LFp2LM,  &
       &          CFt2LM, CFp2LM
#else
   use RMS, only: get_nl_RMS, transform_to_lm_RMS, compute_lm_forces,       &
       &          transform_to_grid_RMS, dtVrLM, dtVtLM, dtVpLM, dpkindrLM, &
       &          Advt2LM, Advp2LM, PFt2LM, PFp2LM, LFrLM, LFt2LM, LFp2LM,  &
       &          CFt2LM, CFp2LM
#endif
   use probe_mod

   implicit none

   private

   type, public, extends(rIter_t) :: rIter_batched_t
      type(grid_space_arrays_3d_t) :: gsa
      type(TO_arrays_t) :: TO_arrays
      type(dtB_arrays_t) :: dtB_arrays
      type(nonlinear_lm_t) :: nl_lm
   contains
      procedure :: initialize
      procedure :: finalize
      procedure :: radialLoop
      procedure :: transform_to_grid_space
      procedure :: transform_to_lm_space
   end type rIter_batched_t

   complex(cp), allocatable :: dLw(:,:), dLz(:,:), dLdw(:,:), dLddw(:,:), dmdw(:,:), dmz(:,:)

contains

   subroutine initialize(this)

      class(rIter_batched_t) :: this

#ifdef WITH_OMP_GPU
      integer :: lm, nR
      lm=0; nR=0
#endif

      call this%gsa%initialize(nRstart,nRstop)
      if ( l_TO ) call this%TO_arrays%initialize()
      call this%dtB_arrays%initialize()
      call this%nl_lm%initialize(n_spec_space_lmP)

      allocate(dLw(lm_max,nRstart:nRstop), dLz(lm_max,nRstart:nRstop))
      allocate(dLdw(lm_max,nRstart:nRstop), dLddw(lm_max,nRstart:nRstop))
      allocate(dmdw(lm_max,nRstart:nRstop), dmz(lm_max,nRstart:nRstop))
#ifdef WITH_OMP_GPU
      !$omp target enter data map(alloc: dLw, dLz, dLdw, dLddw, dmdw, dmz)
      !$omp target teams distribute parallel do collapse(2)
      do lm = 1, lm_max
         do nR=nRstart,nRstop
            dLw(lm,nR)   = zero
            dLz(lm,nR)   = zero
            dLdw(lm,nR)  = zero
            dLddw(lm,nR) = zero
            dmdw(lm,nR)  = zero
            dmz(lm,nR)   = zero
         end do
      end do
      !$omp end target teams distribute parallel do
#endif

   end subroutine initialize
!------------------------------------------------------------------------------
   subroutine finalize(this)

      class(rIter_batched_t) :: this

      call this%gsa%finalize()
      if ( l_TO ) call this%TO_arrays%finalize()
      call this%dtB_arrays%finalize()
      call this%nl_lm%finalize()

#ifdef WITH_OMP_GPU
      !$omp target exit data map(delete: dLw, dLz, dLdw, dLddw, dmdw, dmz)
#endif
      deallocate( dLw, dLz, dLdw, dLddw, dmdw, dmz )

   end subroutine finalize
!------------------------------------------------------------------------------
   subroutine radialLoop(this,l_graph,l_frame,time,timeStage,tscheme,dtLast, &
              &          lTOCalc,lTONext,lTONext2,lHelCalc,lPowerCalc,       &
              &          lRmsCalc,lPressCalc,lPressNext,lViscBcCalc,         &
              &          lFluxProfCalc,lPerpParCalc,lGeosCalc,lHemiCalc,     &
              &          l_probe_out,dsdt,dwdt,dzdt,dpdt,dxidt,dphidt,dbdt,  &
              &          djdt,dVxVhLM,dVxBhLM,dVSrLM,dVXirLM,                &
              &          lorentz_torque_ic,lorentz_torque_ma,br_vt_lm_cmb,   &
              &          br_vp_lm_cmb,br_vt_lm_icb,br_vp_lm_icb,dtrkc,dthkc)
      !
      ! This subroutine handles the main loop over the radial levels. It calls
      ! the SH transforms, computes the nonlinear terms on the grid and bring back
      ! the quantities in spectral space. This is the most time consuming part
      ! of MagIC.
      !

      class(rIter_batched_t) :: this

      !--- Input of variables:
      logical,             intent(in) :: l_graph,l_frame
      logical,             intent(in) :: lTOcalc,lTONext,lTONext2,lHelCalc
      logical,             intent(in) :: lPowerCalc,lHemiCalc
      logical,             intent(in) :: lViscBcCalc,lFluxProfCalc,lPerpParCalc
      logical,             intent(in) :: lRmsCalc,lGeosCalc
      logical,             intent(in) :: l_probe_out
      logical,             intent(in) :: lPressCalc
      logical,             intent(in) :: lPressNext
      real(cp),            intent(in) :: time,timeStage,dtLast
      class(type_tscheme), intent(in) :: tscheme

      !-- Output variables
      complex(cp), intent(out) :: dwdt(lm_max,nRstart:nRstop)
      complex(cp), intent(out) :: dzdt(lm_max,nRstart:nRstop)
      complex(cp), intent(out) :: dsdt(lm_max,nRstart:nRstop)
      complex(cp), intent(out) :: dxidt(lm_max,nRstart:nRstop)
      complex(cp), intent(out) :: dphidt(lm_max,nRstart:nRstop)
      complex(cp), intent(out) :: dpdt(lm_max,nRstart:nRstop)
      complex(cp), intent(out) :: dbdt(lm_maxMag,nRstartMag:nRstopMag)
      complex(cp), intent(out) :: djdt(lm_maxMag,nRstartMag:nRstopMag)
      complex(cp), intent(out) :: dVSrLM(lm_max,nRstart:nRstop)
      complex(cp), intent(out) :: dVXirLM(lm_max,nRstart:nRstop)
      complex(cp), intent(out) :: dVxVhLM(lm_max,nRstart:nRstop)
      complex(cp), intent(out) :: dVxBhLM(lm_maxMag,nRstartMag:nRstopMag)

      !---- Output of nonlinear products for nonlinear
      !     magnetic boundary conditions (needed in s_updateB.f):
      complex(cp), intent(out) :: br_vt_lm_cmb(:) ! product br*vt at CMB
      complex(cp), intent(out) :: br_vp_lm_cmb(:) ! product br*vp at CMB
      complex(cp), intent(out) :: br_vt_lm_icb(:) ! product br*vt at ICB
      complex(cp), intent(out) :: br_vp_lm_icb(:) ! product br*vp at ICB
      real(cp),    intent(out) :: lorentz_torque_ma, lorentz_torque_ic

      !-- Courant citeria:
      real(cp),    intent(out) :: dtrkc(nRstart:nRstop),dthkc(nRstart:nRstop)

      integer :: nR, nBc, idx1, idx2, idxh1, idxh2, idxm1, idxm2, idxa1, idxa2
      integer :: idxc1, idxc2, idxp1, idxp2
      logical :: lMagNlBc

#ifdef WITH_OMP_GPU
      !$omp target update to(w_Rloc, z_Rloc, s_Rloc, &
      !$omp&                 aj_Rloc, b_Rloc, &
      !$omp&                 dw_Rloc, ddw_Rloc, &
      !$omp&                 dz_Rloc, ds_Rloc, db_Rloc, ddb_Rloc, dj_Rloc, &
      !$omp&                 p_Rloc, xi_Rloc, phi_Rloc)
#endif

      if ( l_graph ) then
#ifdef WITH_MPI
         call graphOut_mpi_header(time)
#else
         call graphOut_header(time)
#endif
      end if

      idxh1=1; idxh2=1; idxm1=1; idxm2=1; idxa1=1; idxa2=1
      idxc1=1; idxc2=1; idxp1=1; idxp2=1

      if ( rank == 0 ) then
         dtrkc(n_r_cmb)=1.e10_cp
         dthkc(n_r_cmb)=1.e10_cp
      elseif (rank == n_procs-1) then
         dtrkc(n_r_icb)=1.e10_cp
         dthkc(n_r_icb)=1.e10_cp
      end if

      !------ Set nonlinear terms that are possibly needed at the boundaries.
      !       They may be overwritten by get_td later.
      if ( rank == 0 ) then
         if ( l_heat ) dVSrLM(:,n_r_cmb) =zero
         if ( l_chemical_conv ) dVXirLM(:,n_r_cmb)=zero
         if ( l_mag ) dVxBhLM(:,n_r_cmb)=zero
         if ( l_double_curl ) dVxVhLM(:,n_r_cmb)=zero
      else if (rank == n_procs-1) then
         if ( l_heat ) dVSrLM(:,n_r_icb) =zero
         if ( l_chemical_conv ) dVXirLM(:,n_r_icb)=zero
         if ( l_mag ) dVxBhLM(:,n_r_icb)=zero
         if ( l_double_curl ) dVxVhLM(:,n_r_icb)=zero
      end if

      !------ Having to calculate non-linear boundary terms?
      lMagNlBc=.false.
      if ( ( l_mag_nl .or. l_mag_kin ) .and.                          &
           &       ( ktopv == 1 .or. l_cond_ma .or.                   &
           &          ( ktopv == 2 .and. l_rot_ma ) ) .or.            &
           &       ( kbotv == 1 .or. l_cond_ic .or.                   &
           &          ( kbotv == 2 .and. l_rot_ic ) ) )               &
           &     lMagNlBc=.true.

      call this%nl_lm%set_zero()

      !-- Transform arrays to grid space
      if ( .not. l_onset ) then
#ifdef WITH_OMP_GPU
         !$omp target update to(this%gsa)
#endif

         call lm2phy_counter%start_count()
         call this%transform_to_grid_space(lViscBcCalc, lRmsCalc,                &
              &                            lPressCalc, lTOCalc, lPowerCalc,      &
              &                            lFluxProfCalc, lPerpParCalc, lHelCalc,&
              &                            lHemiCalc, lGeosCalc, l_frame)
         call lm2phy_counter%stop_count(l_increment=.false.)

         !-- Compute nonlinear terms on grid
         call nl_counter%start_count()
         call this%gsa%get_nl(nRstart, nRstop, timeStage)
         call nl_counter%stop_count(l_increment=.false.)

#ifdef WITH_OMP_GPU
         !$omp target update from(this%gsa)
#endif

         !-- Get nl loop for r.m.s. computation
         if ( l_RMS ) then
            call get_nl_RMS(1,this%gsa%vrc,this%gsa%vtc,this%gsa%vpc,this%gsa%dvrdrc, &
                 &          this%gsa%dvrdtc,this%gsa%dvrdpc,this%gsa%dvtdrc,          &
                 &          this%gsa%dvtdpc,this%gsa%dvpdrc,this%gsa%dvpdpc,          &
                 &          this%gsa%cvrc,this%gsa%Advt,this%gsa%Advp,this%gsa%LFt,   &
                 &          this%gsa%LFp,tscheme,lRmsCalc)
         end if

         !--------- Calculate courant condition parameters:
         !if ( .not. l_full_sphere .or. nR /= n_r_icb ) then
         dtrkc(:)=1e10_cp
         dthkc(:)=1e10_cp
         call courant_batch(nRstart, nRstop, dtrkc(nRstart:nRstop),              &
              &             dthkc(nRstart:nRstop), this%gsa%vrc,                 &
              &             this%gsa%vtc,this%gsa%vpc,this%gsa%brc,this%gsa%btc, &
              &             this%gsa%bpc, tscheme%courfac, tscheme%alffac)
         !end if

         !-- Transform back to LM space
         call phy2lm_counter%start_count()
         call this%transform_to_lm_space(nRstart, nRstop, lRmsCalc)
         call phy2lm_counter%stop_count(l_increment=.false.)

#ifdef WITH_OMP_GPU
         !$omp target update from(this%gsa)
         !$omp target update from(this%nl_lm)
#endif
      end if

      do nR=nRstart,nRstop
         nBc = 0
         if ( nR == n_r_cmb ) then
            nBc = ktopv
         else if ( nR == n_r_icb ) then
            nBc = kbotv
         end if

         if ( l_parallel_solve .or. (l_single_matrix .and. l_temperature_diff) ) then
            ! We will need the nonlinear terms on ricb for the pressure l=m=0
            ! equation
            nBc=0
         end if

         if ( lTOCalc ) call this%TO_arrays%set_zero()

         if ( lTOnext .or. lTOnext2 .or. lTOCalc ) then
            call prep_TO_axi(z_Rloc(:,nR), dz_Rloc(:,nR))
         end if

         lorentz_torque_ma = 0.0_cp
         lorentz_torque_ic = 0.0_cp

         !---- Calculation of nonlinear products needed for conducting mantle or
         !     conducting inner core if free stress BCs are applied:
         !     input are brc,vtc,vpc in (theta,phi) space (plus omegaMA and ..)
         !     ouput are the products br_vt_lm_icb, br_vt_lm_cmb, br_vp_lm_icb,
         !     and br_vp_lm_cmb in lm-space, respectively the contribution
         !     to these products from the points theta(nThetaStart)-theta(nThetaStop)
         !     These products are used in get_b_nl_bcs.
         if ( nR == n_r_cmb .and. l_b_nl_cmb ) then
            br_vt_lm_cmb(:)=zero
            br_vp_lm_cmb(:)=zero
            call get_br_v_bcs(nR, this%gsa%brc, this%gsa%vtc, this%gsa%vpc,omega_ma,  &
                 &            br_vt_lm_cmb, br_vp_lm_cmb)
         else if ( nR == n_r_icb .and. l_b_nl_icb ) then
            br_vt_lm_icb(:)=zero
            br_vp_lm_icb(:)=zero
            call get_br_v_bcs(nR, this%gsa%brc, this%gsa%vtc, this%gsa%vpc, omega_ic,  &
                 &            br_vt_lm_icb, br_vp_lm_icb)
         end if
         !--------- Calculate Lorentz torque on inner core:
         !          each call adds the contribution of the theta-block to
         !          lorentz_torque_ic
         if ( nR == n_r_icb .and. l_mag_LF .and. l_rot_ic .and. l_cond_ic  ) then
            call get_lorentz_torque(lorentz_torque_ic, this%gsa%brc,  &
                 &                  this%gsa%bpc, nR)
         end if

         !--------- Calculate Lorentz torque on mantle:
         !          note: this calculates a torque of a wrong sign.
         !          sign is reversed at the end of the theta blocking.
         if ( nR == n_r_cmb .and. l_mag_LF .and. l_rot_ma .and. l_cond_ma ) then
            call get_lorentz_torque(lorentz_torque_ma, this%gsa%brc, &
                 &                  this%gsa%bpc, nR)
         end if

         !--------- Since the fields are given at gridpoints here, this is a good
         !          point for graphical output:
         if ( l_graph ) then
#ifdef WITH_MPI
            call graphOut_mpi(nR,this%gsa%vrc,this%gsa%vtc,this%gsa%vpc, &
                 &            this%gsa%brc,this%gsa%btc,this%gsa%bpc,    &
                 &            this%gsa%sc,this%gsa%pc,this%gsa%xic,      &
                 &            this%gsa%phic)
#else
            call graphOut(nR,this%gsa%vrc,this%gsa%vtc,this%gsa%vpc,     &
                 &        this%gsa%brc,this%gsa%btc,this%gsa%bpc,        &
                 &        this%gsa%sc,this%gsa%pc,this%gsa%xic,          &
                 &        this%gsa%phic)
#endif
         end if

         if ( l_probe_out ) then
            call probe_out(time, nR, this%gsa%vpc, this%gsa%brc, this%gsa%btc)
         end if

         !--------- Helicity output:
         if ( lHelCalc ) then
            call get_helicity(this%gsa%vrc,this%gsa%vtc,this%gsa%vpc,         &
                 &            this%gsa%cvrc,this%gsa%dvrdtc,this%gsa%dvrdpc,  &
                 &            this%gsa%dvtdrc,this%gsa%dvpdrc,nR)
         end if


         !-- North/South hemisphere differences
         if ( lHemiCalc ) then
            call get_hemi(this%gsa%vrc,this%gsa%vtc,this%gsa%vpc,nR,'V')
            if ( l_mag ) call get_hemi(this%gsa%brc,this%gsa%btc,this%gsa%bpc,nR,'B')
         end if

         !-- Viscous heating:
         if ( lPowerCalc ) then
            call get_visc_heat(this%gsa%vrc,this%gsa%vtc,this%gsa%vpc,          &
                 &             this%gsa%cvrc,this%gsa%dvrdrc,this%gsa%dvrdtc,   &
                 &             this%gsa%dvrdpc,this%gsa%dvtdrc,this%gsa%dvtdpc, &
                 &             this%gsa%dvpdrc,this%gsa%dvpdpc,nR)
         end if

         !-- horizontal velocity :
         if ( lViscBcCalc ) then
            call get_nlBLayers(this%gsa%vtc,this%gsa%vpc,this%gsa%dvtdrc,    &
                 &             this%gsa%dvpdrc,this%gsa%drSc,this%gsa%dsdtc, &
                 &             this%gsa%dsdpc,nR)
         end if

         !-- Radial flux profiles
         if ( lFluxProfCalc ) then
            call get_fluxes(this%gsa%vrc,this%gsa%vtc,this%gsa%vpc,            &
                 &          this%gsa%dvrdrc,this%gsa%dvtdrc,this%gsa%dvpdrc,   &
                 &          this%gsa%dvrdtc,this%gsa%dvrdpc,this%gsa%sc,       &
                 &          this%gsa%pc,this%gsa%brc,this%gsa%btc,this%gsa%bpc,&
                 &          this%gsa%cbtc,this%gsa%cbpc,nR)
         end if

         !-- Kinetic energy in the solid and liquid phases
         if ( l_phase_field ) then
            call get_ekin_solid_liquid(this%gsa%vrc,this%gsa%vtc,this%gsa%vpc, &
                 &                     this%gsa%phic,nR)
         end if

         !-- Kinetic energy parallel and perpendicular to rotation axis
         if ( lPerpParCalc ) then
            call get_perpPar(this%gsa%vrc,this%gsa%vtc,this%gsa%vpc,nR)
         end if

         !-- Geostrophic/non-geostrophic flow components
         if ( lGeosCalc ) then
            call calcGeos(this%gsa%vrc,this%gsa%vtc,this%gsa%vpc,this%gsa%cvrc, &
                 &        this%gsa%dvrdpc,this%gsa%dvpdrc,nR)
         end if

         !--------- Movie output:
         if ( l_frame .and. l_movie_oc .and. l_store_frame ) then
            call store_movie_frame(nR,this%gsa%vrc,this%gsa%vtc,this%gsa%vpc,      &
                 &                 this%gsa%brc,this%gsa%btc,this%gsa%bpc,         &
                 &                 this%gsa%sc,this%gsa%drSc,this%gsa%xic,         &
                 &                 this%gsa%phic,this%gsa%dvrdpc,                  &
                 &                 this%gsa%dvpdrc,this%gsa%dvtdrc,this%gsa%dvrdtc,&
                 &                 this%gsa%cvrc,this%gsa%cbrc,this%gsa%cbtc)
         end if

         !--------- Stuff for special output:
         !--------- Calculation of magnetic field production and advection terms
         !          for graphic output:
         if ( l_dtB ) then
#ifdef WITH_OMP_GPU
            !$omp target update to(this%dtB_arrays)
#endif
            call get_dtBLM(nR,this%gsa%vrc,this%gsa%vtc,this%gsa%vpc,       &
                 &         this%gsa%brc,this%gsa%btc,this%gsa%bpc,          &
                 &         this%dtB_arrays%BtVrLM,this%dtB_arrays%BpVrLM,   &
                 &         this%dtB_arrays%BrVtLM,this%dtB_arrays%BrVpLM,   &
                 &         this%dtB_arrays%BtVpLM,this%dtB_arrays%BpVtLM,   &
                 &         this%dtB_arrays%BrVZLM,this%dtB_arrays%BtVZLM,   &
                 &         this%dtB_arrays%BpVtBtVpCotLM,                   &
                 &         this%dtB_arrays%BpVtBtVpSn2LM,                   &
                 &         this%dtB_arrays%BtVZsn2LM)
#ifdef WITH_OMP_GPU
            !$omp target update from(this%dtB_arrays)
#endif
         end if


         !--------- Torsional oscillation terms:
         if ( lTONext .or. lTONext2 ) then
            call getTOnext(this%gsa%brc,this%gsa%btc,this%gsa%bpc,lTONext, &
                 &         lTONext2,tscheme%dt(1),dtLast,nR)
         end if

         if ( lTOCalc ) then
            call getTO(this%gsa%vrc,this%gsa%vtc,this%gsa%vpc,this%gsa%cvrc,   &
                 &     this%gsa%dvpdrc,this%gsa%brc,this%gsa%btc,this%gsa%bpc, &
                 &     this%gsa%cbrc,this%gsa%cbtc,this%TO_arrays%dzRstrLM,    &
                 &     this%TO_arrays%dzAstrLM,this%TO_arrays%dzCorLM,         &
                 &     this%TO_arrays%dzLFLM,dtLast,nR)
         end if

         !-- Partial calculation of time derivatives (horizontal parts):
         !   input flm...  is in (l,m) space at radial grid points nR !
         !   Only dVxBh needed for boundaries !
         !   get_td finally calculates the d*dt terms needed for the
         !   time step performed in s_LMLoop.f . This should be distributed
         !   over the different models that s_LMLoop.f parallelizes over.
         call td_counter%start_count()
         idx1 = (nR-nRstart)*(lmP_max)+1
         idx2 = idx1+lmP_max-1
         if ( l_heat ) then
            idxh1 = idx1; idxh2 = idx2
         end if
         if ( l_chemical_conv ) then
            idxc1 = idx1; idxc2 = idx2
         end if
         if ( l_mag ) then
            idxm1 = idx1; idxm2 = idx2
         end if
         if ( l_anel ) then
            idxa1 = idx1; idxa2 = idx2
         end if
         if ( l_phase_field ) then
            idxp1 = idx1; idxp2 = idx2
         end if
         call this%nl_lm%get_td(nR, nBc, lPressNext, this%nl_lm%AdvrLM(idx1:idx2), &
              &                 this%nl_lm%AdvtLM(idx1:idx2), this%nl_lm%AdvpLM(idx1:idx2),              &
              &                 this%nl_lm%VSrLM(idxh1:idxh2),  &
              &                 this%nl_lm%VStLM(idxh1:idxh2),                &
              &                 this%nl_lm%VXirLM(idxc1:idxc2),              &
              &                 this%nl_lm%VXitLM(idxc1:idxc2),       &
              &                 this%nl_lm%VxBrLM(idxm1:idxm2), this%nl_lm%VxBtLM(idxm1:idxm2),              &
              &                 this%nl_lm%VxBpLM(idxm1:idxm2), this%nl_lm%heatTermsLM(idxa1:idxa2),         &
              &                 this%nl_lm%dphidtLM(idxp1:idxp2), dVSrLM(:,nR), dVXirLM(:,nR),  &
              &                 dVxVhLM(:,nR), dVxBhLM(:,nR), dwdt(:,nR),          &
              &                 dzdt(:,nR), dpdt(:,nR), dsdt(:,nR), dxidt(:,nR),   &
              &                 dphidt(:,nR), dbdt(:,nR), djdt(:,nR))
         call td_counter%stop_count(l_increment=.false.)

         !-- Finish computation of r.m.s. forces
         if ( lRmsCalc ) then
            call compute_lm_forces(nR, dtVrLM(idx1:idx2), dtVtLM(idx1:idx2),       &
                 &                 dtVpLM(idx1:idx2), dpkindrLM(idx1:idx2),        &
                 &                 Advt2LM(idx1:idx2), Advp2LM(idx1:idx2),         &
                 &                 PFt2LM(idx1:idx2), PFp2LM(idx1:idx2),           &
                 &                 LFrLM(idx1:idx2), LFt2LM(idx1:idx2),            &
                 &                 LFp2LM(idx1:idx2), CFt2LM(idx1:idx2),           &
                 &                 CFp2LM(idx1:idx2), w_Rloc(:,nR), dw_Rloc(:,nR), &
                 &                 ddw_Rloc(:,nR), z_Rloc(:,nR), s_Rloc(:,nR),     &
                 &                 xi_Rloc(:,nR), p_Rloc(:,nR), dp_Rloc(:,nR),     &
                 &                 this%nl_lm%AdvrLM(idx1:idx2))
         end if

         !-- Finish calculation of TO variables:
         if ( lTOcalc ) then
            call getTOfinish(nR, dtLast, this%TO_arrays%dzRstrLM,             &
                 &           this%TO_arrays%dzAstrLM, this%TO_arrays%dzCorLM, &
                 &           this%TO_arrays%dzLFLM)
         end if

         !--- Form partial horizontal derivaties of magnetic production and
         !    advection terms:
         if ( l_dtB ) then
            call get_dH_dtBLM(nR,this%dtB_arrays%BtVrLM,this%dtB_arrays%BpVrLM, &
                 &            this%dtB_arrays%BrVtLM,this%dtB_arrays%BrVpLM,    &
                 &            this%dtB_arrays%BtVpLM,this%dtB_arrays%BpVtLM,    &
                 &            this%dtB_arrays%BrVZLM,this%dtB_arrays%BtVZLM,    &
                 &            this%dtB_arrays%BpVtBtVpCotLM,                    &
                 &            this%dtB_arrays%BpVtBtVpSn2LM)
         end if

      end do

      phy2lm_counter%n_counts=phy2lm_counter%n_counts+1
      lm2phy_counter%n_counts=lm2phy_counter%n_counts+1
      nl_counter%n_counts=nl_counter%n_counts+1
      td_counter%n_counts=td_counter%n_counts+1

      !----- Correct sign of mantle Lorentz torque (see above):
      lorentz_torque_ma=-lorentz_torque_ma

   end subroutine radialLoop
!-------------------------------------------------------------------------------
   subroutine transform_to_grid_space(this, lViscBcCalc, lRmsCalc,            &
              &                       lPressCalc, lTOCalc, lPowerCalc,        &
              &                       lFluxProfCalc, lPerpParCalc, lHelCalc,  &
              &                       lHemiCalc, lGeosCalc, l_frame)
      !
      ! This subroutine actually handles the spherical harmonic transforms from
      ! (\ell,m) space to (\theta,\phi) space.
      !

      class(rIter_batched_t) :: this

      !--Input variables
      logical, intent(in) :: lViscBcCalc, lRmsCalc, lPressCalc, lTOCalc, lPowerCalc
      logical, intent(in) :: lFluxProfCalc, lPerpParCalc, lHelCalc, l_frame
      logical, intent(in) :: lGeosCalc, lHemiCalc

      !-- Local variables
      integer :: nR, nPhi
#ifdef WITH_OMP_GPU
      integer :: nLat
#endif

      nR = 0
#ifdef WITH_OMP_GPU
      nLat=0; nPhi=0
#endif

      call legPrep_qst(w_Rloc, ddw_Rloc, z_Rloc, dLw, dLddw, dLz)
      call legPrep_flow(dw_Rloc, z_Rloc, dLdw, dmdw, dmz)

      if ( l_conv .or. l_mag_kin ) then
         if ( l_heat ) then
#ifdef WITH_OMP_GPU
            call scal_to_spat(sht_l_gpu, s_Rloc, this%gsa%sc, l_R(1), .true.)
#else
            call scal_to_spat(sht_l, s_Rloc, this%gsa%sc, l_R(1))
#endif
            if ( lViscBcCalc ) then
#ifdef WITH_OMP_GPU
               call scal_to_grad_spat(s_Rloc, this%gsa%dsdtc, this%gsa%dsdpc, l_R(1), .true.)
#else
               call scal_to_grad_spat(s_Rloc, this%gsa%dsdtc, this%gsa%dsdpc, l_R(1))
#endif
               if ( nRstart == n_r_cmb .and. ktops==1) then
#ifdef WITH_OMP_GPU
                  !-- nlat_padded,nRl:nRu,n_phi_max
                  !$omp target teams distribute parallel do collapse(2)
                  do nLat=1,nlat_padded
                     do nPhi=1,n_phi_max
                        this%gsa%dsdtc(nLat,n_r_cmb,nPhi)=0.0_cp
                        this%gsa%dsdpc(nLat,n_r_cmb,nPhi)=0.0_cp
                     end do
                  end do
                  !$omp end target teams distribute parallel do
#else
                  this%gsa%dsdtc(:,n_r_cmb,:)=0.0_cp
                  this%gsa%dsdpc(:,n_r_cmb,:)=0.0_cp
#endif
               else if ( nRstop == n_r_icb .and. kbots==1) then
#ifdef WITH_OMP_GPU
                  !$omp target teams distribute parallel do collapse(2)
                  do nLat=1,nlat_padded
                     do nPhi=1,n_phi_max
                        this%gsa%dsdtc(nLat,n_r_icb,nPhi)=0.0_cp
                        this%gsa%dsdpc(nLat,n_r_icb,nPhi)=0.0_cp
                     end do
                  end do
                  !$omp end target teams distribute parallel do
#else
                  this%gsa%dsdtc(:,n_r_icb,:)=0.0_cp
                  this%gsa%dsdpc(:,n_r_icb,:)=0.0_cp
#endif
               end if
            end if
         end if

#ifdef WITH_OMP_GPU
         if ( lRmsCalc ) call transform_to_grid_RMS_batch(1, p_Rloc) ! 1 for l_R(nR)
#else
         if ( lRmsCalc ) call transform_to_grid_RMS(1, p_Rloc) ! 1 for l_R(nR)
#endif

         !-- Pressure
#ifdef WITH_OMP_GPU
         if ( lPressCalc ) call scal_to_spat(sht_l_gpu, p_Rloc, this%gsa%pc, l_R(1), .true.)
#else
         if ( lPressCalc ) call scal_to_spat(sht_l, p_Rloc, this%gsa%pc, l_R(1))
#endif

         !-- Composition
#ifdef WITH_OMP_GPU
         if ( l_chemical_conv ) call scal_to_spat(sht_l_gpu, xi_Rloc, this%gsa%xic, l_R(1), .true.)
#else
         if ( l_chemical_conv ) call scal_to_spat(sht_l, xi_Rloc, this%gsa%xic, l_R(1))
#endif

         !-- Phase field
#ifdef WITH_OMP_GPU
         if ( l_phase_field ) call scal_to_spat(sht_l_gpu, phi_Rloc, this%gsa%phic, l_R(1), .true.)
#else
         if ( l_phase_field ) call scal_to_spat(sht_l, phi_Rloc, this%gsa%phic, l_R(1))
#endif

         if ( l_HT .or. lViscBcCalc ) then
#ifdef WITH_OMP_GPU
            call scal_to_spat(sht_l_gpu, ds_Rloc, this%gsa%drsc, l_R(1), .true.)
#else
            call scal_to_spat(sht_l, ds_Rloc, this%gsa%drsc, l_R(1))
#endif
         endif

         !-- pol, sph, tor > ur,ut,up
#ifdef WITH_OMP_GPU
         call torpol_to_spat(dLw, dw_Rloc, z_Rloc, &
              &              this%gsa%vrc, this%gsa%vtc, this%gsa%vpc, l_R(1), .true.)
#else
         call torpol_to_spat(dLw, dw_Rloc, z_Rloc, &
              &              this%gsa%vrc, this%gsa%vtc, this%gsa%vpc, l_R(1))
#endif

         !-- Advection is treated as u \times \curl u
         if ( l_adv_curl ) then
            !-- z,dz,w,dd< -> wr,wt,wp
#ifdef WITH_OMP_GPU
            call torpol_to_spat(dLz, dz_Rloc, dLddw,            &
                 &              this%gsa%cvrc, this%gsa%cvtc,   &
                 &              this%gsa%cvpc, l_R(1), .true.)
#else
            call torpol_to_spat(dLz, dz_Rloc, dLddw,            &
                 &              this%gsa%cvrc, this%gsa%cvtc,   &
                 &              this%gsa%cvpc, l_R(1))
#endif

            !-- For some outputs one still need the other terms
            if ( lViscBcCalc .or. lPowerCalc .or. lRmsCalc .or. lFluxProfCalc &
            &    .or. lTOCalc .or. lHelCalc .or. lPerpParCalc .or. lGeosCalc  &
            &    .or. lHemiCalc .or. ( l_frame .and. l_movie_oc .and.         &
            &    l_store_frame) ) then
#ifdef WITH_OMP_GPU
               call torpol_to_spat(dLdw, ddw_Rloc, dz_Rloc,           &
                    &              this%gsa%dvrdrc, this%gsa%dvtdrc,  &
                    &              this%gsa%dvpdrc, l_R(1), .true.)
               call scal_to_grad_spat(dLw, this%gsa%dvrdtc, &
                    &                this%gsa%dvrdpc, l_R(1), .true.)
               call sphtor_to_spat(sht_l_gpu, dmdw,  dmz, this%gsa%dvtdpc, &
                    &              this%gsa%dvpdpc, l_R(1), .true.)
               !$omp target teams distribute parallel do collapse(3)
               do nLat=1,nlat_padded
                  do nPhi=1,n_phi_max
                     do nR=nRstart,nRstop
                        this%gsa%dvtdpc(nLat,nR,nPhi)=this%gsa%dvtdpc(nLat,nR,nPhi)*O_sin_theta_E2(nLat)
                        this%gsa%dvpdpc(nLat,nR,nPhi)=this%gsa%dvpdpc(nLat,nR,nPhi)*O_sin_theta_E2(nLat)
                     end do
                  end do
               end do
               !$omp end target teams distribute parallel do
#else
               call torpol_to_spat(dLdw, ddw_Rloc, dz_Rloc,           &
                    &              this%gsa%dvrdrc, this%gsa%dvtdrc,  &
                    &              this%gsa%dvpdrc, l_R(1))
               call scal_to_grad_spat(dLw, this%gsa%dvrdtc, &
                    &                this%gsa%dvrdpc, l_R(1))
               call sphtor_to_spat(sht_l, dmdw,  dmz, this%gsa%dvtdpc, &
                    &              this%gsa%dvpdpc, l_R(1))
               !$omp parallel do default(shared) private(nR)
               do nPhi=1,n_phi_max
                  do nR=nRstart,nRstop
                     this%gsa%dvtdpc(:,nR,nPhi)=this%gsa%dvtdpc(:,nR,nPhi)*O_sin_theta_E2(:)
                     this%gsa%dvpdpc(:,nR,nPhi)=this%gsa%dvpdpc(:,nR,nPhi)*O_sin_theta_E2(:)
                  end do
               end do
               !$omp end parallel do
#endif
            end if

         else ! Advection is treated as u\grad u

#ifdef WITH_OMP_GPU
            call torpol_to_spat(dLdw, ddw_Rloc, dz_Rloc,            &
                 &              this%gsa%dvrdrc, this%gsa%dvtdrc,   &
                 &              this%gsa%dvpdrc, l_R(1), .true.)

            call scal_to_spat(sht_l_gpu, dLz, this%gsa%cvrc, l_R(1), .true.)

            call scal_to_grad_spat(dLw, this%gsa%dvrdtc, this%gsa%dvrdpc,&
                 &                 l_R(1), .true.)
            call sphtor_to_spat(sht_l_gpu, dmdw, dmz, this%gsa%dvtdpc, &
                 &              this%gsa%dvpdpc, l_R(1), .true.)
            !$omp target teams distribute parallel do collapse(3)
            do nLat=1,nlat_padded
               do nPhi=1,n_phi_max
                  do nR=nRstart,nRstop
                     this%gsa%dvtdpc(nLat,nR,nPhi)=this%gsa%dvtdpc(nLat,nR,nPhi)*O_sin_theta_E2(nLat)
                     this%gsa%dvpdpc(nLat,nR,nPhi)=this%gsa%dvpdpc(nLat,nR,nPhi)*O_sin_theta_E2(nLat)
                  end do
               end do
            end do
            !$omp end target teams distribute parallel do
#else
            call torpol_to_spat(dLdw, ddw_Rloc, dz_Rloc,            &
                 &              this%gsa%dvrdrc, this%gsa%dvtdrc,   &
                 &              this%gsa%dvpdrc, l_R(1))

            call scal_to_spat(sht_l, dLz, this%gsa%cvrc, l_R(1))

            call scal_to_grad_spat(dLw, this%gsa%dvrdtc, this%gsa%dvrdpc,&
                 &                 l_R(1))
            call sphtor_to_spat(sht_l, dmdw, dmz, this%gsa%dvtdpc, &
                 &              this%gsa%dvpdpc, l_R(1))
            !$omp parallel do default(shared) private(nR)
            do nPhi=1,n_phi_max
               do nR=nRstart,nRstop
                  this%gsa%dvtdpc(:,nR,nPhi)=this%gsa%dvtdpc(:,nR,nPhi)*O_sin_theta_E2(:)
                  this%gsa%dvpdpc(:,nR,nPhi)=this%gsa%dvpdpc(:,nR,nPhi)*O_sin_theta_E2(:)
               end do
            end do
            !$omp end parallel do
#endif
         end if

#ifdef WITH_OMP_GPU
         if ( nRstart == n_r_cmb .and. ktopv==2 ) then
            call v_rigid_boundary_batch(n_r_cmb, omega_ma, .true., this%gsa%vrc,   &
                 &                      this%gsa%vtc, this%gsa%vpc, this%gsa%cvrc, &
                 &                      this%gsa%dvrdtc, this%gsa%dvrdpc,          &
                 &                      this%gsa%dvtdpc,this%gsa%dvpdpc)
         else if ( nRstop == n_r_icb .and. kbotv==2 ) then
            call v_rigid_boundary_batch(n_r_icb, omega_ic, .true., this%gsa%vrc, &
                 &                      this%gsa%vtc, this%gsa%vpc,              &
                 &                      this%gsa%cvrc, this%gsa%dvrdtc,          &
                 &                      this%gsa%dvrdpc, this%gsa%dvtdpc,        &
                 &                      this%gsa%dvpdpc)
         end if
#else
         if ( nRstart == n_r_cmb .and. ktopv==2 ) then
            call v_rigid_boundary(n_r_cmb, omega_ma, .true., this%gsa%vrc,   &
                 &                this%gsa%vtc, this%gsa%vpc, this%gsa%cvrc, &
                 &                this%gsa%dvrdtc, this%gsa%dvrdpc,          &
                 &                this%gsa%dvtdpc,this%gsa%dvpdpc)
         else if ( nRstop == n_r_icb .and. kbotv==2 ) then
            call v_rigid_boundary(n_r_icb, omega_ic, .true., this%gsa%vrc, &
                 &                this%gsa%vtc, this%gsa%vpc,              &
                 &                this%gsa%cvrc, this%gsa%dvrdtc,          &
                 &                this%gsa%dvrdpc, this%gsa%dvtdpc,        &
                 &                this%gsa%dvpdpc)
         end if
#endif

         !else if ( nBc == 1 ) then ! Stress free
         !    ! TODO don't compute vrc as it is set to 0 afterward
         !   call torpol_to_spat(w_Rloc, dw_Rloc,  z_Rloc(:,nR), &
         !        &              this%gsa%vrc, this%gsa%vtc, this%gsa%vpc, l_R(nR))
         !   this%gsa%vrc(:)=0.0_cp
         !   if ( lDeriv ) then
         !      this%gsa%dvrdtc(:)=0.0_cp
         !      this%gsa%dvrdpc(:)=0.0_cp
         !      call torpol_to_spat(dw_Rloc(:,nR), ddw_Rloc(:,nR), dz_Rloc(:,nR), &
         !           &              this%gsa%dvrdrc, this%gsa%dvtdrc,             &
         !           &              this%gsa%dvpdrc, l_R(nR))
         !      call pol_to_curlr_spat(z_Rloc(:,nR), this%gsa%cvrc, l_R(nR))
         !      call sphtor_to_spat(sht_l, dw_Rloc(:,nR),  z_Rloc(:,nR), &
         !           &              this%gsa%dvtdpc, this%gsa%dvpdpc, l_R(nR))
         !   end if
         !else if ( nBc == 2 ) then
         !   if ( nR == n_r_cmb ) then
         !      call v_rigid_boundary(nR, omega_ma, lDeriv, this%gsa%vrc,        &
         !           &                this%gsa%vtc, this%gsa%vpc, this%gsa%cvrc, &
         !           &                this%gsa%dvrdtc, this%gsa%dvrdpc,          &
         !           &                this%gsa%dvtdpc,this%gsa%dvpdpc)
         !   else if ( nR == n_r_icb ) then
         !      call v_rigid_boundary(nR, omega_ic, lDeriv, this%gsa%vrc,      &
         !           &                this%gsa%vtc, this%gsa%vpc,              &
         !           &                this%gsa%cvrc, this%gsa%dvrdtc,          &
         !           &                this%gsa%dvrdpc, this%gsa%dvtdpc,        &
         !           &                this%gsa%dvpdpc)
         !   end if
         !   if ( lDeriv ) then
         !      call torpol_to_spat(dw_Rloc(:,nR), ddw_Rloc(:,nR), dz_Rloc(:,nR), &
         !           &              this%gsa%dvrdrc, this%gsa%dvtdrc,             &
         !           &              this%gsa%dvpdrc, l_R(nR))
         !   end if
         !end if
      end if

      if ( l_mag .or. l_mag_LF ) then
         call legPrep_qst(b_Rloc, ddb_Rloc, aj_Rloc, dLw, dLddw, dLz)
#ifdef WITH_OMP_GPU
         call torpol_to_spat(dLw, db_Rloc,  aj_Rloc,    &
              &              this%gsa%brc, this%gsa%btc, this%gsa%bpc, l_R(1), .true.)
         call torpol_to_spat(dLz, dj_Rloc,  dLddw,    &
              &              this%gsa%cbrc, this%gsa%cbtc, this%gsa%cbpc, l_R(1), .true.)
#else
         call torpol_to_spat(dLw, db_Rloc,  aj_Rloc,    &
              &              this%gsa%brc, this%gsa%btc, this%gsa%bpc, l_R(1))
         call torpol_to_spat(dLz, dj_Rloc,  dLddw,    &
              &              this%gsa%cbrc, this%gsa%cbtc, this%gsa%cbpc, l_R(1))
#endif
      end if

   end subroutine transform_to_grid_space
!-------------------------------------------------------------------------------
   subroutine transform_to_lm_space(this, nRl, nRu, lRmsCalc)
      !
      ! This subroutine actually handles the spherical harmonic transforms from
      ! (\theta,\phi) space to (\ell,m) space.
      !

      class(rIter_batched_t) :: this

      !-- Input variables
      integer, intent(in) :: nRl
      integer, intent(in) :: nRu
      logical, intent(in) :: lRmsCalc

      !-- Local variables
      integer :: nPhi, nR
#ifdef WITH_OMP_GPU
      integer :: nLat
      nLat=0; nPhi=0
#endif

      nR=0

      if ( l_conv_nl .or. l_mag_LF ) then
#ifdef WITH_OMP_GPU
#ifndef DEFAULT
         !$omp target teams distribute parallel do collapse(3)
         do nLat=1,nlat_padded
            do nR=nRl,nRu
               do nPhi=1,n_phi_max
                  if ( l_conv_nl .and. l_mag_LF ) then
                     if ( nR>n_r_LCR ) then
                        this%gsa%Advr(nLat,nR,nPhi)=this%gsa%Advr(nLat,nR,nPhi) + &
                        &                        this%gsa%LFr(nLat,nR,nPhi)
                        this%gsa%Advt(nLat,nR,nPhi)=this%gsa%Advt(nLat,nR,nPhi) + &
                        &                        this%gsa%LFt(nLat,nR,nPhi)
                        this%gsa%Advp(nLat,nR,nPhi)=this%gsa%Advp(nLat,nR,nPhi) + &
                        &                        this%gsa%LFp(nLat,nR,nPhi)
                     end if
                  else if ( l_mag_LF ) then
                     if ( nR > n_r_LCR ) then
                        this%gsa%Advr(nLat,nR,nPhi) = this%gsa%LFr(nLat,nR,nPhi)
                        this%gsa%Advt(nLat,nR,nPhi) = this%gsa%LFt(nLat,nR,nPhi)
                        this%gsa%Advp(nLat,nR,nPhi) = this%gsa%LFp(nLat,nR,nPhi)
                     else
                        this%gsa%Advr(nLat,nR,nPhi)=0.0_cp
                        this%gsa%Advt(nLat,nR,nPhi)=0.0_cp
                        this%gsa%Advp(nLat,nR,nPhi)=0.0_cp
                     end if
                  end if
                  if ( l_precession ) then
                     this%gsa%Advr(nLat,nR,nPhi)=this%gsa%Advr(nLat,nR,nPhi) + &
                     &                        this%gsa%PCr(nLat,nR,nPhi)
                     this%gsa%Advt(nLat,nR,nPhi)=this%gsa%Advt(nLat,nR,nPhi) + &
                     &                        this%gsa%PCt(nLat,nR,nPhi)
                     this%gsa%Advp(nLat,nR,nPhi)=this%gsa%Advp(nLat,nR,nPhi) + &
                     &                        this%gsa%PCp(nLat,nR,nPhi)
                  end if
                  if ( l_centrifuge ) then
                     this%gsa%Advr(nLat,nR,nPhi)=this%gsa%Advr(nLat,nR,nPhi) + &
                     &                        this%gsa%CAr(nLat,nR,nPhi)
                     this%gsa%Advt(nLat,nR,nPhi)=this%gsa%Advt(nLat,nR,nPhi) + &
                     &                        this%gsa%CAt(nLat,nR,nPhi)
                  end if
               end do
            end do
         end do
         !$omp end target teams distribute parallel do
#else
         !$omp target teams distribute parallel do collapse(2)
#endif
#else
         !$omp parallel do default(shared) private(nR)
#endif
         do nPhi=1,n_phi_max
            do nR=nRl,nRu
               if ( l_conv_nl .and. l_mag_LF ) then

                  if ( nR>n_r_LCR ) then
                     this%gsa%Advr(:,nR,nPhi)=this%gsa%Advr(:,nR,nPhi) + &
                     &                        this%gsa%LFr(:,nR,nPhi)
                     this%gsa%Advt(:,nR,nPhi)=this%gsa%Advt(:,nR,nPhi) + &
                     &                        this%gsa%LFt(:,nR,nPhi)
                     this%gsa%Advp(:,nR,nPhi)=this%gsa%Advp(:,nR,nPhi) + &
                     &                        this%gsa%LFp(:,nR,nPhi)
                  end if
               else if ( l_mag_LF ) then
                  if ( nR > n_r_LCR ) then
                     this%gsa%Advr(:,nR,nPhi) = this%gsa%LFr(:,nR,nPhi)
                     this%gsa%Advt(:,nR,nPhi) = this%gsa%LFt(:,nR,nPhi)
                     this%gsa%Advp(:,nR,nPhi) = this%gsa%LFp(:,nR,nPhi)
                  else
                     this%gsa%Advr(:,nR,nPhi)=0.0_cp
                     this%gsa%Advt(:,nR,nPhi)=0.0_cp
                     this%gsa%Advp(:,nR,nPhi)=0.0_cp
                  end if
               end if

               if ( l_precession ) then
                  this%gsa%Advr(:,nR,nPhi)=this%gsa%Advr(:,nR,nPhi) + &
                  &                        this%gsa%PCr(:,nR,nPhi)
                  this%gsa%Advt(:,nR,nPhi)=this%gsa%Advt(:,nR,nPhi) + &
                  &                        this%gsa%PCt(:,nR,nPhi)
                  this%gsa%Advp(:,nR,nPhi)=this%gsa%Advp(:,nR,nPhi) + &
                  &                        this%gsa%PCp(:,nR,nPhi)
               end if

               if ( l_centrifuge ) then
                  this%gsa%Advr(:,nR,nPhi)=this%gsa%Advr(:,nR,nPhi) + &
                  &                        this%gsa%CAr(:,nR,nPhi)
                  this%gsa%Advt(:,nR,nPhi)=this%gsa%Advt(:,nR,nPhi) + &
                  &                        this%gsa%CAt(:,nR,nPhi)
               end if
            end do
         end do
#ifdef WITH_OMP_GPU
#ifdef DEFAULT
         !$omp end target teams distribute parallel do
#endif
#else
         !$omp end parallel do
#endif

#ifdef WITH_OMP_GPU
         call spat_to_qst(this%gsa%Advr, this%gsa%Advt, this%gsa%Advp, &
              &           this%nl_lm%AdvrLM, this%nl_lm%AdvtLM,        &
              &           this%nl_lm%AdvpLM, l_R(1), .true.)
#else
         call spat_to_qst(this%gsa%Advr, this%gsa%Advt, this%gsa%Advp, &
              &           this%nl_lm%AdvrLM, this%nl_lm%AdvtLM,        &
              &           this%nl_lm%AdvpLM, l_R(1))
#endif
      end if

      if ( l_heat ) then
#ifdef WITH_OMP_GPU
         call spat_to_qst(this%gsa%VSr, this%gsa%VSt, this%gsa%VSp, &
              &           this%nl_lm%VSrLM, this%nl_lm%VStLM,       &
              &           this%nl_lm%VSpLM, l_R(1), .true.)
#else
         call spat_to_qst(this%gsa%VSr, this%gsa%VSt, this%gsa%VSp, &
              &           this%nl_lm%VSrLM, this%nl_lm%VStLM,       &
              &           this%nl_lm%VSpLM, l_R(1))
#endif

#ifdef WITH_OMP_GPU
         if ( l_anel ) call scal_to_SH(sht_lP_gpu, this%gsa%heatTerms, &
                            &          this%nl_lm%heatTermsLM, l_R(1), .true.)
#else
         if ( l_anel ) call scal_to_SH(sht_lP, this%gsa%heatTerms, &
                            &          this%nl_lm%heatTermsLM, l_R(1))
#endif
      end if

      if ( l_chemical_conv ) then
#ifdef WITH_OMP_GPU
         call spat_to_qst(this%gsa%VXir, this%gsa%VXit, this%gsa%VXip, &
              &           this%nl_lm%VXirLM, this%nl_lm%VXitLM,        &
              &           this%nl_lm%VXipLM, l_R(1), .true.)
#else
         call spat_to_qst(this%gsa%VXir, this%gsa%VXit, this%gsa%VXip, &
              &           this%nl_lm%VXirLM, this%nl_lm%VXitLM,        &
              &           this%nl_lm%VXipLM, l_R(1))
#endif
      end if

#ifdef WITH_OMP_GPU
      if( l_phase_field ) call scal_to_SH(sht_lP_gpu, this%gsa%phiTerms,  &
                               &          this%nl_lm%dphidtLM, l_R(1), .true.)
#else
      if( l_phase_field ) call scal_to_SH(sht_lP, this%gsa%phiTerms,  &
                               &          this%nl_lm%dphidtLM, l_R(1))
#endif

      if ( l_mag_nl ) then
         !if ( nR>n_r_LCR ) then
#ifdef WITH_OMP_GPU
         call spat_to_qst(this%gsa%VxBr, this%gsa%VxBt, this%gsa%VxBp, &
              &           this%nl_lm%VxBrLM, this%nl_lm%VxBtLM,        &
              &           this%nl_lm%VxBpLM, l_R(1), .true.)
#else
         call spat_to_qst(this%gsa%VxBr, this%gsa%VxBt, this%gsa%VxBp, &
              &           this%nl_lm%VxBrLM, this%nl_lm%VxBtLM,        &
              &           this%nl_lm%VxBpLM, l_R(1))
#endif
         !else
         !   call spat_to_sphertor(this%gsa%VxBt, this%gsa%VxBp, this%nl_lm%VxBtLM, &
         !        &                this%nl_lm%VxBpLM, l_R(1))
         !end if
      end if

      if ( lRmsCalc ) call transform_to_lm_RMS(1, this%gsa%LFr) ! 1 for l_R(1)

   end subroutine transform_to_lm_space
!-------------------------------------------------------------------------------
   subroutine legPrep_flow(dw, z, dLdw, dmdw, dmz)
      !
      ! This routine is used to compute temporary arrays required before
      ! computing the Legendre transforms. This routine is specific to
      ! flow components.
      !

      !-- Input variable
      complex(cp), intent(in) :: dw(lm_max,nRstart:nRstop) ! radial derivative of wlm
      complex(cp), intent(in) :: z(lm_max,nRstart:nRstop)  ! zlm

      !-- Output variable
      complex(cp), intent(out) :: dLdw(lm_max,nRstart:nRstop) ! l(l+1) * dw
      complex(cp), intent(out) :: dmdw(lm_max,nRstart:nRstop) ! i * m * dw
      complex(cp), intent(out) :: dmz(lm_max,nRstart:nRstop)  ! i * m * z

      !-- Local variables
      integer :: lm, l, m, nR

#ifdef WITH_OMP_GPU
      !$omp target teams distribute parallel do
#else
      !$omp parallel do default(shared) private(l, m, lm)
#endif
      do nR=nRstart,nRstop
         do lm = 1, lm_max
            l = st_map%lm2l(lm)
            m = st_map%lm2m(lm)
            if ( l <= l_R(nR) ) then
               dLdw(lm,nR) = dLh(lm) * dw(lm,nR)
               dmdw(lm,nR) = ci * m * dw(lm,nR)
               dmz(lm,nR)  = ci * m * z(lm,nR)
            else
               dLdw(lm,nR) = zero
               dmdw(lm,nR) = zero
               dmz(lm,nR)  = zero
            end if
         end do
      end do
#ifdef WITH_OMP_GPU
      !$omp end target teams distribute parallel do
#else
      !$omp end parallel do
#endif

   end subroutine legPrep_flow
!-------------------------------------------------------------------------------
   subroutine legPrep_qst(w, ddw, z, dLw, dLddw, dLz)
      !
      ! This routine is used to compute temporary arrays required before
      ! computing the Legendre transforms.
      !

      !-- Input variable
      complex(cp), intent(in) :: w(lm_max,nRstart:nRstop) ! Poloidal potential wlm
      complex(cp), intent(in) :: ddw(lm_max,nRstart:nRstop) ! Second radial derivative of wlm
      complex(cp), intent(in) :: z(lm_max,nRstart:nRstop) ! Toroidal potential zlm

      !-- Output variable
      complex(cp), intent(out) :: dLw(lm_max,nRstart:nRstop) ! l(l+1) * wlm
      complex(cp), intent(out) :: dLddw(lm_max,nRstart:nRstop) ! l(l+1)/r^2 * wlm-ddwlm
      complex(cp), intent(out) :: dLz(lm_max,nRstart:nRstop) ! l(l+1) * zlm

      !-- Local variables
      integer :: lm, l, nR

#ifdef WITH_OMP_GPU
      !$omp target teams distribute parallel do
#else
      !$omp parallel do default(shared) private(l, lm)
#endif
      do nR=nRstart,nRstop
         do lm = 1, lm_max
            l = st_map%lm2l(lm)
            if ( l <= l_R(nR) ) then
               dLw(lm,nR)   = dLh(lm) *  w(lm,nR)
               dLz(lm,nR)   = dLh(lm) *  z(lm,nR)
               dLddw(lm,nR) = or2(nR) * dLh(lm) * w(lm,nR) - ddw(lm,nR)
            else
               dLw(lm,nR)   = zero
               dLddw(lm,nR) = zero
               dLz(lm,nR)   = zero
            end if
         end do
      end do
#ifdef WITH_OMP_GPU
      !$omp end target teams distribute parallel do
#else
      !$omp end parallel do
#endif

   end subroutine legPrep_qst
!-------------------------------------------------------------------------------
end module rIter_batched_mod