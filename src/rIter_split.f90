module rIter_split

   use precision_mod
   use constants, only: zero
   use fields
   use num_param, only: phy2lm_counter, lm2phy_counter, nl_counter,  &
       &                td_counter
   use truncation, only: n_lmP_loc, nRstart, nRstop, nRstartMag, nRstopMag,   &
       &                 n_lm_loc, n_lmMag_loc, n_r_cmb, n_r_icb, n_theta_max,&
       &                 n_phi_max, n_theta_loc, n_m_max, nThetaStart,        &
       &                 nThetaStop
   use nonlinear_3D_lm_mod, only: nonlinear_3D_lm_t
   use hybrid_space_mod, only: hybrid_3D_arrays_t
   use grid_space_arrays_3d_mod, only: grid_3D_arrays_t
   use dtB_arrays_mod, only: dtB_arrays_t
   use TO_arrays_mod, only: TO_arrays_t
   use torsional_oscillations, only: prep_TO_axi, getTO, getTOnext, getTOfinish
   use dtB_mod, only: get_dtBLM, get_dH_dtBLM
   use out_movie, only: store_movie_frame
   use nl_special_calc
   use time_schemes, only: type_tscheme
   use radial_functions, only: or2, orho1
   use physical_parameters, only: ktopv, kbotv, n_r_LCR
   use courant_mod, only: courant
   use outRot, only: get_lorentz_torque
   use nonlinear_bcs, only: get_br_v_bcs, v_rigid_boundary
   use logic, only: l_TO, l_mag, l_chemical_conv, l_heat, l_double_curl,   &
       &            l_mag_LF, l_store_frame, l_adv_curl, l_HT, l_movie_oc, &
       &            l_rot_ic, l_cond_ic, l_full_sphere, l_cond_ma,         &
       &            l_b_nl_cmb, l_b_nl_icb, l_rot_ma, l_precession,        &
       &            l_centrifuge, l_conv_nl, l_mag_nl, l_mag_kin, l_anel,  &
       &            l_dtB
#ifdef WITH_MPI
   use graphOut_mod, only: graphOut_mpi_header, graphOut_mpi
#else
   use graphOut_mod, only: graphOut_header, graphOut
#endif
   use parallel_mod, only: n_ranks_r, coord_r, get_openmp_blocks
   use fft, only: fft_phi_loc, fft_phi_many, ifft_phi

   implicit none

   private

   type, public :: rIter_split_t
      type(grid_3D_arrays_t) :: gsa
      type(hybrid_3D_arrays_t) :: hsa
      type(TO_arrays_t) :: TO_arrays
      type(dtB_arrays_t) :: dtB_arrays
      type(nonlinear_3D_lm_t) :: nl_lm
   contains 
      procedure :: initialize
      procedure :: finalize
      procedure :: radialLoop
      procedure, private :: phys_loop
      procedure, private :: td_loop
      procedure, private :: fft_hyb_to_grid
      procedure, private :: fft_grid_to_hyb
      procedure, private :: fft_hyb_to_grid_loop
      procedure, private :: fft_grid_to_hyb_loop
   end type rIter_split_t

contains

   subroutine initialize(this)

      class(rIter_split_t) :: this

      call this%gsa%initialize()
      call this%hsa%initialize()
      if ( l_TO ) call this%TO_arrays%initialize()
      call this%dtB_arrays%initialize(n_lmP_loc)
      call this%nl_lm%initialize(n_lmP_loc, nRstart, nRstop)

   end subroutine initialize
!-----------------------------------------------------------------------------------
   subroutine finalize(this)

      class(rIter_split_t) :: this

      call this%gsa%finalize()
      call this%hsa%finalize()
      if ( l_TO ) call this%TO_arrays%finalize()
      call this%dtB_arrays%finalize()
      call this%nl_lm%finalize()

   end subroutine finalize
!-----------------------------------------------------------------------------------
   subroutine radialLoop(this,l_graph,l_frame,time,timeStage,tscheme,dtLast, &
              &          lTOCalc,lTONext,lTONext2,lHelCalc,lPowerCalc,       &
              &          lRmsCalc,lPressCalc,lPressNext,lViscBcCalc,         &
              &          lFluxProfCalc,lPerpParCalc,l_probe_out,dsdt,        &
              &          dwdt,dzdt,dpdt,dxidt,dbdt,djdt,dVxVhLM,dVxBhLM,     &
              &          dVSrLM,dVXirLM,lorentz_torque_ic,                   &
              &          lorentz_torque_ma,br_vt_lm_cmb,br_vp_lm_cmb,        &
              &          br_vt_lm_icb,br_vp_lm_icb,HelASr,Hel2ASr,           &
              &          HelnaASr,Helna2ASr,HelEAASr,viscAS,uhASr,           &
              &          duhASr,gradsASr,fconvASr,fkinASr,fviscASr,          &
              &          fpoynASr,fresASr,EperpASr,EparASr,                  &
              &          EperpaxiASr,EparaxiASr,dtrkc,dthkc)


      class(rIter_split_t) :: this

      !--- Input of variables:
      logical,             intent(in) :: l_graph,l_frame
      logical,             intent(in) :: lTOcalc,lTONext,lTONext2,lHelCalc
      logical,             intent(in) :: lPowerCalc
      logical,             intent(in) :: lViscBcCalc,lFluxProfCalc,lPerpParCalc
      logical,             intent(in) :: lRmsCalc
      logical,             intent(in) :: l_probe_out
      logical,             intent(in) :: lPressCalc
      logical,             intent(in) :: lPressNext
      real(cp),            intent(in) :: time,timeStage,dtLast
      class(type_tscheme), intent(in) :: tscheme

      !---- Output of explicit time step:
      !---- dVSrLM and dVxBhLM are output of contributions to explicit time step that
      !     need a further treatment (radial derivatives required):
      complex(cp), intent(out) :: dwdt(n_lm_loc,nRstart:nRstop)
      complex(cp), intent(out) :: dzdt(n_lm_loc,nRstart:nRstop)
      complex(cp), intent(out) :: dpdt(n_lm_loc,nRstart:nRstop)
      complex(cp), intent(out) :: dsdt(n_lm_loc,nRstart:nRstop)
      complex(cp), intent(out) :: dxidt(n_lm_loc,nRstart:nRstop)
      complex(cp), intent(out) :: dVSrLM(n_lm_loc,nRstart:nRstop)
      complex(cp), intent(out) :: dVXirLM(n_lm_loc,nRstart:nRstop)
      complex(cp), intent(out) :: dbdt(n_lmMag_loc,nRstartMag:nRstopMag)
      complex(cp), intent(out) :: djdt(n_lmMag_loc,nRstartMag:nRstopMag)
      complex(cp), intent(out) :: dVxVhLM(n_lm_loc,nRstart:nRstop)
      complex(cp), intent(out) :: dVxBhLM(n_lmMag_loc,nRstartMag:nRstopMag)
      real(cp),    intent(out) :: lorentz_torque_ma,lorentz_torque_ic

      !---- inoutput for axisymmetric helicity:
      real(cp),    intent(inout) :: HelASr(2,nRstart:nRstop)
      real(cp),    intent(inout) :: Hel2ASr(2,nRstart:nRstop)
      real(cp),    intent(inout) :: HelnaASr(2,nRstart:nRstop)
      real(cp),    intent(inout) :: Helna2ASr(2,nRstart:nRstop)
      real(cp),    intent(inout) :: HelEAASr(nRstart:nRstop)
      real(cp),    intent(inout) :: uhASr(nRstart:nRstop)
      real(cp),    intent(inout) :: duhASr(nRstart:nRstop)
      real(cp),    intent(inout) :: viscAS(nRstart:nRstop)
      real(cp),    intent(inout) :: gradsASr(nRstart:nRstop)
      real(cp),    intent(inout) :: fkinASr(nRstart:nRstop)
      real(cp),    intent(inout) :: fconvASr(nRstart:nRstop)
      real(cp),    intent(inout) :: fviscASr(nRstart:nRstop)
      real(cp),    intent(inout) :: fresASr(nRstartMag:nRstopMag)
      real(cp),    intent(inout) :: fpoynASr(nRstartMag:nRstopMag)
      real(cp),    intent(inout) :: EperpASr(nRstart:nRstop)
      real(cp),    intent(inout) :: EparASr(nRstart:nRstop)
      real(cp),    intent(inout) :: EperpaxiASr(nRstart:nRstop)
      real(cp),    intent(inout) :: EparaxiASr(nRstart:nRstop)

      !---- inoutput of nonlinear products for nonlinear
      !     magnetic boundary conditions (needed in s_updateB.f):
      complex(cp), intent(out) :: br_vt_lm_cmb(n_lmP_loc) ! product br*vt at CMB
      complex(cp), intent(out) :: br_vp_lm_cmb(n_lmP_loc) ! product br*vp at CMB
      complex(cp), intent(out) :: br_vt_lm_icb(n_lmP_loc) ! product br*vt at ICB
      complex(cp), intent(out) :: br_vp_lm_icb(n_lmP_loc) ! product br*vp at ICB

      !---- inoutput for Courant criteria:
      real(cp),    intent(out) :: dtrkc(nRstart:nRstop),dthkc(nRstart:nRstop)

      !-- Local variables:
      logical :: lGraphHeader, lMagNlBc

      lGraphHeader=l_graph
      if ( lGraphHeader ) then
#ifdef WITH_MPI
         call graphOut_mpi_header(time,1,n_theta_max)
#else
         call graphOut_header(time)
#endif
      end if

      if ( coord_r == 0 ) then
         dtrkc(n_r_cmb)=1.e10_cp
         dthkc(n_r_cmb)=1.e10_cp
      elseif (coord_r == n_ranks_r-1) then
         dtrkc(n_r_icb)=1.e10_cp
         dthkc(n_r_icb)=1.e10_cp
      end if

      !------ Set nonlinear terms that are possibly needed at the boundaries.
      !       They may be overwritten by get_td later.
      if ( coord_r == 0 ) then
         if ( l_heat ) dVSrLM(:,n_r_cmb) =zero
         if ( l_chemical_conv ) dVXirLM(:,n_r_cmb)=zero
         if ( l_mag ) dVxBhLM(:,n_r_cmb)=zero
         if ( l_double_curl ) dVxVhLM(:,n_r_cmb)=zero
      else if (coord_r == n_ranks_r-1) then
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


      call lm2phy_counter%start_count()
      !-- Legendre transforms
      call this%hsa%leg_spec_to_hyb(w_Rdist, dw_Rdist, ddw_Rdist, z_Rdist, dz_Rdist, &
           &                        b_Rdist, db_Rdist, ddb_Rdist, aj_Rdist, dj_Rdist,&
           &                        s_Rdist, ds_Rdist, p_Rdist, xi_Rdist,            &
           &                        lViscBcCalc, lRmsCalc, lPressCalc, lTOCalc,      &
           &                        lPowerCalc, lFluxProfCalc, lPerpParCalc,         &
           &                        lHelCalc, l_frame)

      !-- Transposes
      call this%hsa%transp_Mloc_to_Thloc(lViscBcCalc, lRmsCalc, lPressCalc, lTOCalc, &
           &                             lPowerCalc, lFluxProfCalc, l_frame)

      !-- FFT's
      call this%fft_hyb_to_grid(lViscBcCalc,lRmsCalc,lPressCalc,lTOCalc,lPowerCalc, &
           &                    lFluxProfCalc,lPerpParCalc,lHelCalc,l_frame)
      call lm2phy_counter%stop_count()

      !-- Physical space loop
      call this%phys_loop(l_graph,l_frame,time,timeStage,tscheme,dtLast,    &
              &          lTOCalc,lTONext,lTONext2,lHelCalc,lPowerCalc,      &
              &          lRmsCalc,lPressCalc,lPressNext,lViscBcCalc,        &
              &          lMagNlBc,lFluxProfCalc,lPerpParCalc,l_probe_out,   &
              &          lorentz_torque_ic,lorentz_torque_ma,br_vt_lm_cmb,  &
              &          br_vp_lm_cmb,br_vt_lm_icb,br_vp_lm_icb,HelASr,     &
              &          Hel2ASr,HelnaASr,Helna2ASr,HelEAASr,viscAS,uhASr,  &
              &          duhASr,gradsASr,fconvASr,fkinASr,fviscASr,         &
              &          fpoynASr,fresASr,EperpASr,EparASr,                 &
              &          EperpaxiASr,EparaxiASr,dtrkc,dthkc)
      nl_counter%n_counts = nl_counter%n_counts+1

      call phy2lm_counter%start_count()
      !-- FFT's
      call this%fft_grid_to_hyb(lRmsCalc)

      !-- Transposes
      call this%hsa%transp_Thloc_to_Mloc(lRmsCalc)

      !-- Legendre transforms
      call this%hsa%leg_hyb_to_spec(this%nl_lm, lRmsCalc)
      call phy2lm_counter%stop_count()

      !-- get td and other spectral calls
      call td_counter%start_count()
      call this%td_loop(lMagNlBc, lRmsCalc, lPressNext, dVSrLM, dVXirLM, dVxVhLM,  &
           &            dVxBhLM, dwdt, dzdt, dpdt, dsdt, dxidt, dbdt, djdt)
      call td_counter%stop_count()

      !----- Correct sign of mantle Lorentz torque (see above):
      lorentz_torque_ma=-lorentz_torque_ma

   end subroutine radialLoop
!-----------------------------------------------------------------------------------
   subroutine td_loop(this, lMagNlBc, lRmsCalc, lPressNext, dVSrLM, dVXirLM, &
              &       dVxVhLM, dVxBhLM, dwdt, dzdt, dpdt, dsdt, dxidt, dbdt, djdt)

      class(rIter_split_t) :: this

      !-- Input variables
      logical, intent(in) :: lMagNlBc
      logical, intent(in) :: lRmsCalc
      logical, intent(in) :: lPressNext

      !-- Output of variables:
      complex(cp), intent(out) :: dwdt(n_lm_loc,nRstart:nRstop)
      complex(cp), intent(out) :: dzdt(n_lm_loc,nRstart:nRstop)
      complex(cp), intent(out) :: dpdt(n_lm_loc,nRstart:nRstop)
      complex(cp), intent(out) :: dsdt(n_lm_loc,nRstart:nRstop)
      complex(cp), intent(out) :: dxidt(n_lm_loc,nRstart:nRstop)
      complex(cp), intent(out) :: dVSrLM(n_lm_loc,nRstart:nRstop)
      complex(cp), intent(out) :: dVXirLM(n_lm_loc,nRstart:nRstop)
      complex(cp), intent(out) :: dbdt(n_lmMag_loc,nRstartMag:nRstopMag)
      complex(cp), intent(out) :: djdt(n_lmMag_loc,nRstartMag:nRstopMag)
      complex(cp), intent(out) :: dVxVhLM(n_lm_loc,nRstart:nRstop)
      complex(cp), intent(out) :: dVxBhLM(n_lmMag_loc,nRstartMag:nRstopMag)

      !-- Local variables:
      logical :: l_bound
      integer :: nR, nBc

      do nR=nRstart,nRstop
         l_bound = ( nR==n_r_icb) .or. ( nR==n_r_cmb)
         nBc = 0
         if ( nR == n_r_cmb ) then
            nBc = ktopv
         else if ( nR == n_r_icb ) then
            nBc = kbotv
         end if

         if ( l_mag .and. l_bound .and. (.not. lMagNlBc) .and. (.not. lRmsCalc)) then
            this%nl_lm%VxBtLM(:,nR)=zero
            this%nl_lm%VxBpLM(:,nR)=zero
         end if

         call this%nl_lm%get_td(nR, nBc, lRmsCalc, lPressNext, dVSrLM(:,nR),    &
              &                 dVXirLM(:,nR), dVxVhLM(:,nR), dVxBhLM(:,nR),    &
              &                 dwdt(:,nR), dzdt(:,nR), dpdt(:,nR), dsdt(:,nR), &
              &                 dxidt(:,nR), dbdt(:,nR), djdt(:,nR))

         !@> TODO: to be continued with additional I/O's
      end do

   end subroutine td_loop
!-----------------------------------------------------------------------------------
   subroutine phys_loop(this,l_graph,l_frame,time,timeStage,tscheme,dtLast, &
              &          lTOCalc,lTONext,lTONext2,lHelCalc,lPowerCalc,      &
              &          lRmsCalc,lPressCalc,lPressNext,lVisc,lMagNlBc,     &
              &          lFluxProfCalc,lPerpParCalc,l_probe_out,            &
              &          lorentz_torque_ic,lorentz_torque_ma,br_vt_lm_cmb,  &
              &          br_vp_lm_cmb,br_vt_lm_icb,br_vp_lm_icb,HelAS,      &
              &          Hel2AS,HelnaAS,Helna2AS,HelEAAS,viscAS,uhAS,       &
              &          duhAS,gradsAS,fconvAS,fkinAS,fviscAS,              &
              &          fpoynAS,fresAS,EperpAS,EparAS,                     &
              &          EperpaxiAS,EparaxiAS,dtrkc,dthkc)

      class(rIter_split_t) :: this
      real(cp),            intent(in) :: time,timeStage,dtLast
      class(type_tscheme), intent(in) :: tscheme
      logical,             intent(in) :: l_graph,l_frame
      logical,             intent(in) :: lTOcalc,lTONext,lTONext2,lHelCalc
      logical,             intent(in) :: lPowerCalc
      logical,             intent(in) :: lVisc,lFluxProfCalc,lPerpParCalc
      logical,             intent(in) :: lRmsCalc, lMagNlBc
      logical,             intent(in) :: l_probe_out
      logical,             intent(in) :: lPressCalc
      logical,             intent(in) :: lPressNext


      !---- inoutput for Courant criteria:
      !     magnetic boundary conditions (needed in s_updateB.f):
      real(cp),    intent(out) :: lorentz_torque_ma,lorentz_torque_ic
      complex(cp), intent(out) :: br_vt_lm_cmb(n_lmP_loc) ! product br*vt at CMB
      complex(cp), intent(out) :: br_vp_lm_cmb(n_lmP_loc) ! product br*vp at CMB
      complex(cp), intent(out) :: br_vt_lm_icb(n_lmP_loc) ! product br*vt at ICB
      complex(cp), intent(out) :: br_vp_lm_icb(n_lmP_loc) ! product br*vp at ICB
      real(cp),    intent(out) :: HelAS(2,nRstart:nRstop),Hel2AS(2,nRstart:nRstop)
      real(cp),    intent(out) :: HelnaAS(2,nRstart:nRstop),Helna2AS(2,nRstart:nRstop)
      real(cp),    intent(out) :: HelEAAS(nRstart:nRstop), viscAS(nRstart:nRstop)
      real(cp),    intent(out) :: uhAS(nRstart:nRstop), duhAS(nRstart:nRstop)
      real(cp),    intent(out) :: gradsAS(nRstart:nRstop), fconvAS(nRstart:nRstop)
      real(cp),    intent(out) :: fkinAS(nRstart:nRstop), fviscAS(nRstart:nRstop)
      real(cp),    intent(out) :: fpoynAS(nRstart:nRstop), fresAS(nRstart:nRstop)
      real(cp),    intent(out) :: EperpAS(nRstart:nRstop), EparAS(nRstart:nRstop)
      real(cp),    intent(out) :: EperpaxiAS(nRstart:nRstop), EparaxiAS(nRstart:nRstop)

      !---- inoutput for Courant criteria:
      real(cp),    intent(inout) :: dtrkc(nRstart:nRstop),dthkc(nRstart:nRstop)


      !--Local variables
      integer :: nR, nBc, nPhi, nTheta, nThStart, nThStop
      logical :: lDeriv, l_Bound
      logical :: lGraphHeader=.false.

      call this%nl_lm%set_zero()

      do nR=nRstart,nRstop
         l_Bound = ( nR == n_r_icb ) .or. ( nR == n_r_cmb )
         nBc = 0
         lDeriv = .true.
         if ( nR == n_r_cmb ) then
            nBc = ktopv
            lDeriv= lTOCalc .or. lHelCalc .or. l_frame .or. lPerpParCalc   &
            &       .or. lVisc .or. lFluxProfCalc .or. lRmsCalc .or.       &
            &       lPowerCalc
         else if ( nR == n_r_icb ) then
            nBc = kbotv
            lDeriv= lTOCalc .or. lHelCalc .or. l_frame  .or. lPerpParCalc  &
            &       .or. lVisc .or. lFluxProfCalc .or. lRmsCalc .or.       &
            &       lPowerCalc
         end if

         dtrkc(nR)=1e10_cp
         dthkc(nR)=1e10_cp

         if ( lTOCalc ) call this%TO_arrays%set_zero()

         if ( lTOnext .or. lTOnext2 .or. lTOCalc ) then
            call prep_TO_axi(z_Rdist(:,nR), dz_Rdist(:,nR))
         end if

         lorentz_torque_ma = 0.0_cp
         lorentz_torque_ic = 0.0_cp

         if ( nBc == 2 ) then
            if ( nR == n_r_cmb ) then
               call v_rigid_boundary(nR, omega_ma, lDeriv, this%gsa%vrc(:,:,nR),    &
                    &                this%gsa%vtc(:,:,nR), this%gsa%vpc(:,:,nR),    &
                    &                this%gsa%cvrc(:,:,nR), this%gsa%dvrdtc(:,:,nR),&
                    &                this%gsa%dvrdpc(:,:,nR),                       &
                    &                this%gsa%dvtdpc(:,:,nR), this%gsa%dvpdpc(:,:,nR))
            else if ( nR == n_r_icb ) then
               call v_rigid_boundary(nR, omega_ic, lDeriv, this%gsa%vrc(:,:,nR),    &
                    &                this%gsa%vtc(:,:,nR), this%gsa%vpc(:,:,nR),    &
                    &                this%gsa%cvrc(:,:,nR), this%gsa%dvrdtc(:,:,nR),&
                    &                this%gsa%dvrdpc(:,:,nR),                       &
                    &                this%gsa%dvtdpc(:,:,nR), this%gsa%dvpdpc(:,:,nR))
            end if
         end if

         call nl_counter%start_count()
         if ( .not. l_bound .or. lRmsCalc .or. lMagNlBc ) then
            call this%gsa%get_nl(timeStage, tscheme, nR, nBc, lRmsCalc)
         end if
         call nl_counter%stop_count(l_increment=.false.)

         if ( (.not. l_bound .or. lRmsCalc ) .and. (l_conv_nl .or. l_mag_LF) ) then

            !$omp parallel default(shared) private(nThStart,nThStop,nTheta,nPhi)
            nThStart=nThetaStart; nThStop=nThetaStop
            call get_openmp_blocks(nThStart,nThStop)

            if ( l_conv_nl .and. l_mag_LF ) then
               if ( nR>n_r_LCR ) then
                  do nTheta=nThStart,nThStop
                     do nPhi=1,n_phi_max
                        this%gsa%Advr(nPhi,nTheta,nR)=this%gsa%Advr(nPhi,nTheta,nR)+&
                        &                             this%gsa%LFr(nPhi,nTheta,nR)
                        this%gsa%Advt(nPhi,nTheta,nR)=this%gsa%Advt(nPhi,nTheta,nR)+&
                        &                             this%gsa%LFt(nPhi,nTheta,nR)
                        this%gsa%Advp(nPhi,nTheta,nR)=this%gsa%Advp(nPhi,nTheta,nR)+&
                        &                             this%gsa%LFp(nPhi,nTheta,nR)
                     end do
                  end do
               end if
            else if ( l_mag_LF ) then
               if ( nR > n_r_LCR ) then
                  do nTheta=nThStart,nThStop
                     do nPhi=1,n_phi_max
                        this%gsa%Advr(nPhi,nTheta,nR)=this%gsa%LFr(nPhi,nTheta,nR)
                        this%gsa%Advt(nPhi,nTheta,nR)=this%gsa%LFt(nPhi,nTheta,nR)
                        this%gsa%Advp(nPhi,nTheta,nR)=this%gsa%LFp(nPhi,nTheta,nR)
                     end do
                  end do
               else
                  do nTheta=nThStart,nThStop
                     do nPhi=1,n_phi_max
                        this%gsa%Advr(nPhi,nTheta,nR)=0.0_cp
                        this%gsa%Advt(nPhi,nTheta,nR)=0.0_cp
                        this%gsa%Advp(nPhi,nTheta,nR)=0.0_cp
                     end do
                  end do
               end if
            end if

            if ( l_precession ) then
               do nTheta=nThStart,nThStop
                  do nPhi=1,n_phi_max
                     this%gsa%Advr(nPhi,nTheta,nR)=this%gsa%Advr(nPhi,nTheta,nR)+&
                     &                             this%gsa%PCr(nPhi,nTheta,nR)
                     this%gsa%Advt(nPhi,nTheta,nR)=this%gsa%Advt(nPhi,nTheta,nR)+&
                     &                             this%gsa%PCt(nPhi,nTheta,nR)
                     this%gsa%Advp(nPhi,nTheta,nR)=this%gsa%Advp(nPhi,nTheta,nR)+&
                     &                             this%gsa%PCp(nPhi,nTheta,nR)
                  end do
               end do
            end if

            if ( l_centrifuge ) then
               do nTheta=nThStart,nThStop
                  do nPhi=1,n_phi_max
                     this%gsa%Advr(nPhi,nTheta,nR)=this%gsa%Advr(nPhi,nTheta,nR)+&
                     &                             this%gsa%CAr(nPhi,nTheta,nR)
                     this%gsa%Advt(nPhi,nTheta,nR)=this%gsa%Advt(nPhi,nTheta,nR)+&
                     &                             this%gsa%CAt(nPhi,nTheta,nR)
                  end do
               end do
            end if

            !$omp end parallel

         end if

         if ( nR == n_r_cmb .and. l_b_nl_cmb ) then
            br_vt_lm_cmb(:)=zero
            br_vp_lm_cmb(:)=zero
            call get_br_v_bcs(this%gsa%brc(:,:,nR), this%gsa%vtc(:,:,nR),        &
                 &            this%gsa%vpc(:,:,nR), omega_ma, or2(nR),orho1(nR), &
                 &            br_vt_lm_cmb, br_vp_lm_cmb)

         else if ( nR == n_r_icb .and. l_b_nl_icb ) then
            br_vt_lm_icb(:)=zero
            br_vp_lm_icb(:)=zero
            call get_br_v_bcs(this%gsa%brc(:,:,nR), this%gsa%vtc(:,:,nR),         &
                 &            this%gsa%vpc(:,:,nR), omega_ic, or2(nR), orho1(nR), &
                 &            br_vt_lm_icb, br_vp_lm_icb)
         end if

         !-- Calculate Lorentz torque on inner core:
         !   each call adds the contribution of the theta-block to
         !   lorentz_torque_ic
         if ( nR == n_r_icb .and. l_mag_LF .and. l_rot_ic .and. l_cond_ic  ) then
            call get_lorentz_torque(lorentz_torque_ic, this%gsa%brc(:,:,nR), &
                 &                  this%gsa%bpc(:,:,nR), nR)
         end if

         !-- Calculate Lorentz torque on mantle:
         !   note: this calculates a torque of a wrong sign.
         !   sign is reversed at the end of the theta blocking.
         if ( nR == n_r_cmb .and. l_mag_LF .and. l_rot_ma .and. l_cond_ma ) then
            call get_lorentz_torque(lorentz_torque_ma,this%gsa%brc(:,:,nR), &
                 &                  this%gsa%bpc(:,:,nR), nR)
         end if

         !-- Calculate courant condition parameters:
         if ( .not. l_full_sphere .or. nR /= n_r_icb ) then
            call courant(nR,dtrkc(nR),dthkc(nR),this%gsa%vrc(:,:,nR),      &
                 &       this%gsa%vtc(:,:,nR),this%gsa%vpc(:,:,nR),        &
                 &       this%gsa%brc(:,:,nR),this%gsa%btc(:,:,nR),        &
                 &       this%gsa%bpc(:,:,nR), tscheme%courfac, tscheme%alffac)
         end if

         !-- Since the fields are given at gridpoints here, this is a good
         !   point for graphical output:
         if ( l_graph ) then
#ifdef WITH_MPI
            call graphOut_mpi(time,nR,this%gsa%vrc(:,:,nR),this%gsa%vtc(:,:,nR),   &
                 &            this%gsa%vpc(:,:,nR),this%gsa%brc(:,:,nR),           &
                 &            this%gsa%btc(:,:,nR),this%gsa%bpc(:,:,nR),           &
                 &            this%gsa%sc(:,:,nR),this%gsa%pc(:,:,nR),             &
                 &            this%gsa%xic(:,:,nR),lGraphHeader)
#else
            call graphOut(time,nR,this%gsa%vrc(:,:,nR),this%gsa%vtc(:,:,nR),       &
                 &        this%gsa%vpc(:,:,nR),this%gsa%brc(:,:,nR),               &
                 &        this%gsa%btc(:,:,nR),this%gsa%bpc(:,:,nR),               &
                 &        this%gsa%sc(:,:,nR),this%gsa%pc(:,:,nR),                 &
                 &        this%gsa%xic(:,:,nR),lGraphHeader)
#endif
         end if

         !if ( this%l_probe_out ) then
         !   print *, " * probe_out is not ported!!!", __LINE__, __FILE__
         !   call probe_out(time,this%nR,this%gsa%vpc,this%gsa%brc,this%gsa%btc,1, &
         !        &         this%sizeThetaB)
         !end if

         !--------- Helicity output:
         if ( lHelCalc ) then
            call get_helicity(this%gsa%vrc(:,:,nR),this%gsa%vtc(:,:,nR),        &
                 &            this%gsa%vpc(:,:,nR),this%gsa%cvrc(:,:,nR),       &
                 &            this%gsa%dvrdtc(:,:,nR),this%gsa%dvrdpc(:,:,nR),  &
                 &            this%gsa%dvtdrc(:,:,nR),this%gsa%dvpdrc(:,:,nR),  &
                 &            HelAS(:,nR),Hel2AS(:,nR),HelnaAS(:,nR),           &
                 &            Helna2AS(:,nR), HelEAAs(nR),nR)
         end if

         !-- Viscous heating:
         if ( lPowerCalc ) then
            call get_visc_heat(this%gsa%vrc(:,:,nR),this%gsa%vtc(:,:,nR),        &
                 &             this%gsa%vpc(:,:,nR),this%gsa%cvrc(:,:,nR),       &
                 &             this%gsa%dvrdrc(:,:,nR),this%gsa%dvrdtc(:,:,nR),  &
                 &             this%gsa%dvrdpc(:,:,nR),this%gsa%dvtdrc(:,:,nR),  &
                 &             this%gsa%dvtdpc(:,:,nR),this%gsa%dvpdrc(:,:,nR),  &
                 &             this%gsa%dvpdpc(:,:,nR),viscAS(nR),nR)
         end if

         !-- horizontal velocity :
         if ( lVisc ) then
            call get_nlBLayers(this%gsa%vtc(:,:,nR),this%gsa%vpc(:,:,nR),        &
                 &             this%gsa%dvtdrc(:,:,nR),this%gsa%dvpdrc(:,:,nR),  &
                 &             this%gsa%drSc(:,:,nR),this%gsa%dsdtc(:,:,nR),     &
                 &             this%gsa%dsdpc(:,:,nR),uhAS(nR),duhAS(nR),        &
                 &             gradsAS(nR),nR)
         end if

         !-- Radial flux profiles
         if ( lFluxProfCalc ) then
            call get_fluxes(this%gsa%vrc(:,:,nR),this%gsa%vtc(:,:,nR),         &
                 &          this%gsa%vpc(:,:,nR),this%gsa%dvrdrc(:,:,nR),      &
                 &          this%gsa%dvtdrc(:,:,nR),this%gsa%dvpdrc(:,:,nR),   &
                 &          this%gsa%dvrdtc(:,:,nR),this%gsa%dvrdpc(:,:,nR),   &
                 &          this%gsa%sc(:,:,nR),this%gsa%pc(:,:,nR),           &
                 &          this%gsa%brc(:,:,nR),this%gsa%btc(:,:,nR),         &
                 &          this%gsa%bpc(:,:,nR),this%gsa%cbtc(:,:,nR),        &
                 &          this%gsa%cbpc(:,:,nR),fconvAS(nR),fkinAS(nR),      &
                 &          fviscAS(nR),fpoynAS(nR),fresAS(nR),nR)
         end if

         !-- Kinetic energy parallel and perpendicular to rotation axis
         if ( lPerpParCalc ) then
            call get_perpPar(this%gsa%vrc(:,:,nR),this%gsa%vtc(:,:,nR),     &
                 &           this%gsa%vpc(:,:,nR),EperpAS(nR),EparAS(nR),   &
                 &           EperpaxiAS(nR),EparaxiAS(nR),nR )
         end if

         !--------- Movie output:
         if ( l_frame .and. l_movie_oc .and. l_store_frame ) then
            call store_movie_frame(nR,this%gsa%vrc(:,:,nR),this%gsa%vtc(:,:,nR),   &
                 &                 this%gsa%vpc(:,:,nR),this%gsa%brc(:,:,nR),      &
                 &                 this%gsa%btc(:,:,nR),this%gsa%bpc(:,:,nR),      &
                 &                 this%gsa%sc(:,:,nR),this%gsa%drSc(:,:,nR),      &
                 &                 this%gsa%dvrdpc(:,:,nR),this%gsa%dvpdrc(:,:,nR),&
                 &                 this%gsa%dvtdrc(:,:,nR),this%gsa%dvrdtc(:,:,nR),&
                 &                 this%gsa%cvrc(:,:,nR),this%gsa%cbrc(:,:,nR),    &
                 &                 this%gsa%cbtc(:,:,nR),1,n_theta_max)
         end if

         !--------- Stuff for special output:
         !--------- Calculation of magnetic field production and advection terms
         !          for graphic output:
         if ( l_dtB ) then
            call get_dtBLM(nR,this%gsa%vrc(:,:,nR),this%gsa%vtc(:,:,nR),         &
                 &         this%gsa%vpc(:,:,nR),this%gsa%brc(:,:,nR),            &
                 &         this%gsa%btc(:,:,nR),this%gsa%bpc(:,:,nR),            &
                 &         this%dtB_arrays%BtVrLM,                               &
                 &         this%dtB_arrays%BpVrLM,this%dtB_arrays%BrVtLM,        &
                 &         this%dtB_arrays%BrVpLM,this%dtB_arrays%BtVpLM,        &
                 &         this%dtB_arrays%BpVtLM,this%dtB_arrays%BrVZLM,        &
                 &         this%dtB_arrays%BtVZLM,this%dtB_arrays%BtVpCotLM,     &
                 &         this%dtB_arrays%BpVtCotLM,this%dtB_arrays%BtVZcotLM,  &
                 &         this%dtB_arrays%BtVpSn2LM,this%dtB_arrays%BpVtSn2LM,  &
                 &         this%dtB_arrays%BtVZsn2LM)
         end if

         !--------- Torsional oscillation terms:
         if ( ( lTONext .or. lTONext2 ) .and. l_mag ) then
            call getTOnext(this%gsa%brc(:,:,nR), this%gsa%btc(:,:,nR), &
                 &         this%gsa%bpc(:,:,nR), lTONext, lTONext2,    &
                 &         tscheme%dt(1), dtLast, nR)
         end if

         if ( lTOCalc ) then
            call getTO(this%gsa%vrc(:,:,nR),this%gsa%vtc(:,:,nR),          &  
                 &     this%gsa%vpc(:,:,nR),this%gsa%cvrc(:,:,nR),         &
                 &     this%gsa%dvpdrc(:,:,nR),this%gsa%brc(:,:,nR),       &
                 &     this%gsa%btc(:,:,nR),this%gsa%bpc(:,:,nR),          &
                 &     this%gsa%cbrc(:,:,nR),this%gsa%cbtc(:,:,nR),        &
                 &     this%TO_arrays%dzRstrLM,this%TO_arrays%dzAstrLM,    &
                 &     this%TO_arrays%dzCorLM,this%TO_arrays%dzLFLM,dtLast,nR)

            !-- Finish calculation of TO variables:
            call getTOfinish(nR, dtLast, this%TO_arrays%dzRstrLM,              &
                 &           this%TO_arrays%dzAstrLM, this%TO_arrays%dzCorLM,  &
                 &           this%TO_arrays%dzLFLM)
         end if

         !--- Form partial horizontal derivaties of magnetic production and
         !    advection terms:
         if ( l_dtB ) then
            call get_dH_dtBLM(nR,this%dtB_arrays%BtVrLM,this%dtB_arrays%BpVrLM,     &
                 &            this%dtB_arrays%BrVtLM,this%dtB_arrays%BrVpLM,        &
                 &            this%dtB_arrays%BtVpLM,this%dtB_arrays%BpVtLM,        &
                 &            this%dtB_arrays%BrVZLM,this%dtB_arrays%BtVZLM,        &
                 &            this%dtB_arrays%BtVpCotLM,this%dtB_arrays%BpVtCotLM,  &
                 &            this%dtB_arrays%BtVpSn2LM,this%dtB_arrays%BpVtSn2LM)
         end if

      end do

   end subroutine phys_loop
!-----------------------------------------------------------------------------------
   subroutine fft_hyb_to_grid_loop(this,lVisc,lRmsCalc,lPressCalc,lTOCalc,lPowerCalc,&
              &               lFluxProfCalc,lPerpParCalc,lHelCalc,l_frame)

      class(rIter_split_t) :: this
      logical, intent(in) :: lVisc, lRmsCalc, lPressCalc, lPowerCalc
      logical, intent(in) :: lTOCalc, lFluxProfCalc, l_frame, lPerpParCalc
      logical, intent(in) :: lHelCalc

      !--Local variables
      complex(cp) :: F(n_phi_max/2+1,nThetaStart:nThetaStop)
      integer :: nR, nBc
      logical :: lDeriv

      F(:,:) = zero
      do nR=nRstart,nRstop
         nBc = 0
         lDeriv = .true.
         if ( nR == n_r_cmb ) then
            nBc = ktopv
            lDeriv= lTOCalc .or. lHelCalc .or. l_frame .or. lPerpParCalc   &
            &       .or. lVisc .or. lFluxProfCalc .or. lRmsCalc .or.       &
            &       lPowerCalc
         else if ( nR == n_r_icb ) then
            nBc = kbotv
            lDeriv= lTOCalc .or. lHelCalc .or. l_frame  .or. lPerpParCalc  &
            &       .or. lVisc .or. lFluxProfCalc .or. lRmsCalc .or.       &
            &       lPowerCalc
         end if

         if ( l_heat ) then
            F(1:n_m_max,:)=this%hsa%s_Thloc(:,:,nR)
            call fft_phi_loc(this%gsa%sc(:,:,nR),F,-1)
            if ( lVisc ) then
               F(1:n_m_max,:)=this%hsa%dsdt_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%dsdtc(:,:,nR),F,-1)
               F(1:n_m_max,:)=this%hsa%dsdp_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%dsdpc(:,:,nR),F,-1)
            end if
         end if

         if ( lRmsCalc) then
            F(1:n_m_max,:)=this%hsa%dpdt_Thloc(:,:,nR)
            call fft_phi_loc(this%gsa%dpdtc(:,:,nR),F,-1)
            F(1:n_m_max,:)=this%hsa%dpdp_Thloc(:,:,nR)
            call fft_phi_loc(this%gsa%dpdpc(:,:,nR),F,-1)
         end if

         if ( lPressCalc ) then
            F(1:n_m_max,:)=this%hsa%p_Thloc(:,:,nR)
            call fft_phi_loc(this%gsa%pc(:,:,nR),F,-1)
         end if

         if ( l_HT .or. lVisc ) then
            F(1:n_m_max,:)=this%hsa%dsdr_Thloc(:,:,nR)
            call fft_phi_loc(this%gsa%drsc(:,:,nR),F,-1)
         end if

         if ( l_chemical_conv ) then
            F(1:n_m_max,:)=this%hsa%xi_Thloc(:,:,nR)
            call fft_phi_loc(this%gsa%xic(:,:,nR),F,-1)
         end if

         if ( nBc == 0 ) then
            F(1:n_m_max,:)=this%hsa%vr_Thloc(:,:,nR)
            call fft_phi_loc(this%gsa%vrc(:,:,nR),F,-1)
            F(1:n_m_max,:)=this%hsa%vt_Thloc(:,:,nR)
            call fft_phi_loc(this%gsa%vtc(:,:,nR),F,-1)
            F(1:n_m_max,:)=this%hsa%vp_Thloc(:,:,nR)
            call fft_phi_loc(this%gsa%vpc(:,:,nR),F,-1)
            F(1:n_m_max,:)=this%hsa%cvr_Thloc(:,:,nR)
            call fft_phi_loc(this%gsa%cvrc(:,:,nR),F,-1)

            if ( l_adv_curl ) then
               F(1:n_m_max,:)=this%hsa%cvt_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%cvtc(:,:,nR),F,-1)
               F(1:n_m_max,:)=this%hsa%cvp_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%cvpc(:,:,nR),F,-1)

               if ( lVisc .or. lPowerCalc .or. lRmsCalc .or. lFluxProfCalc .or.  &
               &    lTOCalc .or. ( l_frame .and. l_movie_oc .and.                &
               &    l_store_frame) ) then
                  F(1:n_m_max,:)=this%hsa%dvrdr_Thloc(:,:,nR)
                  call fft_phi_loc(this%gsa%dvrdrc(:,:,nR),F,-1)
                  F(1:n_m_max,:)=this%hsa%dvtdr_Thloc(:,:,nR)
                  call fft_phi_loc(this%gsa%dvtdrc(:,:,nR),F,-1)
                  F(1:n_m_max,:)=this%hsa%dvpdr_Thloc(:,:,nR)
                  call fft_phi_loc(this%gsa%dvpdrc(:,:,nR),F,-1)
                  F(1:n_m_max,:)=this%hsa%dvrdp_Thloc(:,:,nR)
                  call fft_phi_loc(this%gsa%dvrdpc(:,:,nR),F,-1)
                  F(1:n_m_max,:)=this%hsa%dvtdp_Thloc(:,:,nR)
                  call fft_phi_loc(this%gsa%dvtdpc(:,:,nR),F,-1)
                  F(1:n_m_max,:)=this%hsa%dvpdp_Thloc(:,:,nR)
                  call fft_phi_loc(this%gsa%dvpdpc(:,:,nR),F,-1)
                  F(1:n_m_max,:)=this%hsa%dvrdt_Thloc(:,:,nR)
                  call fft_phi_loc(this%gsa%dvrdtc(:,:,nR),F,-1)
               end if
            else
               F(1:n_m_max,:)=this%hsa%dvrdr_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%dvrdrc(:,:,nR),F,-1)
               F(1:n_m_max,:)=this%hsa%dvtdr_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%dvtdrc(:,:,nR),F,-1)
               F(1:n_m_max,:)=this%hsa%dvpdr_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%dvpdrc(:,:,nR),F,-1)
               F(1:n_m_max,:)=this%hsa%dvrdp_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%dvrdpc(:,:,nR),F,-1)
               F(1:n_m_max,:)=this%hsa%dvtdp_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%dvtdpc(:,:,nR),F,-1)
               F(1:n_m_max,:)=this%hsa%dvpdp_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%dvpdpc(:,:,nR),F,-1)
               F(1:n_m_max,:)=this%hsa%dvrdt_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%dvrdtc(:,:,nR),F,-1)
            end if

         else if ( nBc == 1 ) then ! Strees-free
            this%gsa%vrc(:,:,nR)=0.0_cp
            F(1:n_m_max,:)=this%hsa%vt_Thloc(:,:,nR)
            call fft_phi_loc(this%gsa%vtc(:,:,nR),F,-1)
            F(1:n_m_max,:)=this%hsa%vp_Thloc(:,:,nR)
            call fft_phi_loc(this%gsa%vpc(:,:,nR),F,-1)
            if ( lDeriv ) then
               F(1:n_m_max,:)=this%hsa%cvr_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%cvrc(:,:,nR),F,-1)
               F(1:n_m_max,:)=this%hsa%dvtdp_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%dvtdpc(:,:,nR),F,-1)
               F(1:n_m_max,:)=this%hsa%dvpdp_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%dvpdpc(:,:,nR),F,-1)
            end if

         else if ( nBc == 2 ) then ! Rigid boundary
            if ( lDeriv ) then
               F(1:n_m_max,:)=this%hsa%dvrdr_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%dvrdrc(:,:,nR),F,-1)
               F(1:n_m_max,:)=this%hsa%dvtdr_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%dvtdrc(:,:,nR),F,-1)
               F(1:n_m_max,:)=this%hsa%dvpdr_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%dvpdrc(:,:,nR),F,-1)
            end if
         end if

         if ( l_mag .or. l_mag_LF ) then
            F(1:n_m_max,:)=this%hsa%br_Thloc(:,:,nR)
            call fft_phi_loc(this%gsa%brc(:,:,nR),F,-1)
            F(1:n_m_max,:)=this%hsa%bt_Thloc(:,:,nR)
            call fft_phi_loc(this%gsa%btc(:,:,nR),F,-1)
            F(1:n_m_max,:)=this%hsa%bp_Thloc(:,:,nR)
            call fft_phi_loc(this%gsa%bpc(:,:,nR),F,-1)
            if ( lDeriv ) then
               F(1:n_m_max,:)=this%hsa%cbr_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%cbrc(:,:,nR),F,-1)
               F(1:n_m_max,:)=this%hsa%cbt_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%cbtc(:,:,nR),F,-1)
               F(1:n_m_max,:)=this%hsa%cbp_Thloc(:,:,nR)
               call fft_phi_loc(this%gsa%cbpc(:,:,nR),F,-1)
            end if
         end if
      end do

   end subroutine fft_hyb_to_grid_loop
!-----------------------------------------------------------------------------------
   subroutine fft_hyb_to_grid(this,lVisc,lRmsCalc,lPressCalc,lTOCalc,lPowerCalc, &
              &               lFluxProfCalc,lPerpParCalc,lHelCalc,l_frame)

      class(rIter_split_t) :: this
      logical, intent(in) :: lVisc, lRmsCalc, lPressCalc, lPowerCalc
      logical, intent(in) :: lTOCalc, lFluxProfCalc, l_frame, lPerpParCalc
      logical, intent(in) :: lHelCalc

      if ( l_heat ) then
         call ifft_phi(this%hsa%s_pThloc, this%gsa%sc, 1)
         if ( lVisc ) then
            call ifft_phi(this%hsa%grads_pThloc,this%gsa%grads,3)
         else if ( (.not. lVisc) .and. l_HT ) then
            call ifft_phi(this%hsa%grads_pThloc,this%gsa%grads,1)
         end if
      end if

      if ( lPressCalc ) call ifft_phi(this%hsa%p_pThloc,this%gsa%pc,1)

      if ( lRmsCalc) then
         call ifft_phi(this%hsa%gradp_pThloc,this%gsa%gradp, 2)
      end if

      if ( l_chemical_conv ) call ifft_phi(this%hsa%xi_pThloc, this%gsa%xic, 1)

      if ( l_adv_curl ) then
         call ifft_phi(this%hsa%vel_pThloc, this%gsa%vel, 6)
         if ( lVisc .or. lPowerCalc .or. lRmsCalc .or. lFluxProfCalc .or.  &
         &    lTOCalc .or. ( l_frame .and. l_movie_oc .and.                &
         &    l_store_frame) ) then
            call ifft_phi(this%hsa%gradvel_pThloc, this%gsa%gradvel, 7)
         end if
      else
         call ifft_phi(this%hsa%vel_pThloc, this%gsa%vel, 4)
         call ifft_phi(this%hsa%gradvel_pThloc, this%gsa%gradvel, 7)
      end if

      if ( l_mag .or. l_mag_LF ) call ifft_phi(this%hsa%mag_pThloc, this%gsa%mag, 6)

   end subroutine fft_hyb_to_grid
!-----------------------------------------------------------------------------------
   subroutine fft_grid_to_hyb(this, lRmsCalc)

      class(rIter_split_t) :: this
      logical, intent(in) :: lRmsCalc

      if ( l_conv_nl .or. l_mag_LF ) then
         call fft_phi_many(this%gsa%Advr, this%hsa%Advr_Thloc, 1)
         call fft_phi_many(this%gsa%Advt, this%hsa%Advt_Thloc, 1)
         call fft_phi_many(this%gsa%Advp, this%hsa%Advp_Thloc, 1)
      end if

      if ( lRmsCalc .and. l_mag_LF ) then
         call fft_phi_many(this%gsa%LFr, this%hsa%LFr_Thloc, 1)
         call fft_phi_many(this%gsa%LFt, this%hsa%LFt_Thloc, 1)
         call fft_phi_many(this%gsa%LFp, this%hsa%LFp_Thloc, 1)
      end if

      if ( l_heat ) then
         call fft_phi_many(this%gsa%VSr, this%hsa%VSr_Thloc, 1)
         call fft_phi_many(this%gsa%VSt, this%hsa%VSt_Thloc, 1)
         call fft_phi_many(this%gsa%VSp, this%hsa%VSp_Thloc, 1)
         if ( l_anel ) then
            call fft_phi_many(this%gsa%ViscHeat, this%hsa%ViscHeat_Thloc, 1)
            if ( l_mag_nl ) then
               call fft_phi_many(this%gsa%OhmLoss, this%hsa%OhmLoss_Thloc, 1)
            end if
         end if
      end if

      if ( l_chemical_conv ) then
         call fft_phi_many(this%gsa%VXir, this%hsa%VXir_Thloc, 1)
         call fft_phi_many(this%gsa%VXit, this%hsa%VXit_Thloc, 1)
         call fft_phi_many(this%gsa%VXip, this%hsa%VXip_Thloc, 1)
      end if

      if ( l_mag_nl ) then
         call fft_phi_many(this%gsa%VxBr, this%hsa%VxBr_Thloc, 1)
         call fft_phi_many(this%gsa%VxBt, this%hsa%VxBt_Thloc, 1)
         call fft_phi_many(this%gsa%VxBp, this%hsa%VxBp_Thloc, 1)
      end if

      if ( lRmsCalc ) then
         call fft_phi_many(this%gsa%dpdtc, this%hsa%PFt2_Thloc, 1)
         call fft_phi_many(this%gsa%dpdpc, this%hsa%PFp2_Thloc, 1)
         call fft_phi_many(this%gsa%CFt2, this%hsa%CFt2_Thloc, 1)
         call fft_phi_many(this%gsa%CFp2, this%hsa%CFp2_Thloc, 1)
         call fft_phi_many(this%gsa%dtVr, this%hsa%dtVr_Thloc, 1)
         call fft_phi_many(this%gsa%dtVt, this%hsa%dtVt_Thloc, 1)
         call fft_phi_many(this%gsa%dtVp, this%hsa%dtVp_Thloc, 1)
         if ( l_conv_nl ) then
            call fft_phi_many(this%gsa%Advt2, this%hsa%Advt2_Thloc, 1)
            call fft_phi_many(this%gsa%Advp2, this%hsa%Advp2_Thloc, 1)
         end if
         if ( l_adv_curl ) then
            call fft_phi_many(this%gsa%dpkindrc, this%hsa%dpkindr_Thloc, 1)
         end if
         if ( l_mag_nl ) then
            call fft_phi_many(this%gsa%LFt2, this%hsa%LFt2_Thloc, 1)
            call fft_phi_many(this%gsa%LFp2, this%hsa%LFp2_Thloc, 1)
         end if
      end if

   end subroutine fft_grid_to_hyb
!-----------------------------------------------------------------------------------
   subroutine fft_grid_to_hyb_loop(this, lRmsCalc)

      class(rIter_split_t) :: this
      logical, intent(in) :: lRmsCalc

      !-- Local variables
      integer :: nR
      logical :: l_Bound
      complex(cp) :: F(n_phi_max/2+1,nThetaStart:nThetaStop)

      do nR=nRstart,nRstop
         l_Bound = (nR==n_r_icb) .or. (nR==n_r_cmb)

         if ( (.not. l_bound .or. lRmsCalc) .and. (l_conv_nl .or. l_mag_LF) ) then
            call fft_phi_loc(this%gsa%Advr(:,:,nR), F, 1)
            this%hsa%Advr_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
            call fft_phi_loc(this%gsa%Advt(:,:,nR), F, 1)
            this%hsa%Advt_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
            call fft_phi_loc(this%gsa%Advp(:,:,nR), F, 1)
            this%hsa%Advp_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
            if ( lRmsCalc .and. l_mag_LF .and. nR>n_r_LCR ) then
               call fft_phi_loc(this%gsa%LFr(:,:,nR), F, 1)
               this%hsa%LFr_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
               call fft_phi_loc(this%gsa%LFt(:,:,nR), F, 1)
               this%hsa%LFt_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
               call fft_phi_loc(this%gsa%LFp(:,:,nR), F, 1)
               this%hsa%LFp_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
            end if
         end if

         if ( .not. l_bound .and. l_heat ) then
            call fft_phi_loc(this%gsa%VSr(:,:,nR), F, 1)
            this%hsa%VSr_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
            call fft_phi_loc(this%gsa%VSt(:,:,nR), F, 1)
            this%hsa%VSt_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
            call fft_phi_loc(this%gsa%VSp(:,:,nR), F, 1)
            this%hsa%VSp_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
            if ( l_anel ) then
               call fft_phi_loc(this%gsa%ViscHeat(:,:,nR), F, 1)
               this%hsa%ViscHeat_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
               if ( l_mag_nl .and. nR>n_r_LCR ) then
                  call fft_phi_loc(this%gsa%OhmLoss(:,:,nR), F, 1)
                  this%hsa%OhmLoss_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
               end if
            end if
         end if

         if ( .not. l_bound .and. l_chemical_conv ) then
            call fft_phi_loc(this%gsa%VXir(:,:,nR), F, 1)
            this%hsa%VXir_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
            call fft_phi_loc(this%gsa%VXit(:,:,nR), F, 1)
            this%hsa%VXit_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
            call fft_phi_loc(this%gsa%VXip(:,:,nR), F, 1)
            this%hsa%VXip_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
         end if

         if ( l_mag_nl ) then
            if ( .not. l_bound .and. nR>n_r_LCR ) then
               call fft_phi_loc(this%gsa%VxBr(:,:,nR), F, 1)
               this%hsa%VxBr_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
               call fft_phi_loc(this%gsa%VxBt(:,:,nR), F, 1)
               this%hsa%VxBt_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
               call fft_phi_loc(this%gsa%VxBp(:,:,nR), F, 1)
               this%hsa%VxBp_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
            else
               call fft_phi_loc(this%gsa%VxBt(:,:,nR), F, 1)
               this%hsa%VxBt_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
               call fft_phi_loc(this%gsa%VxBp(:,:,nR), F, 1)
               this%hsa%VxBp_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
            end if
         end if

         if ( lRmsCalc ) then
               call fft_phi_loc(this%gsa%dpdtc(:,:,nR), F, 1)
               this%hsa%PFt2_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
               call fft_phi_loc(this%gsa%dpdpc(:,:,nR), F, 1)
               this%hsa%PFp2_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
               call fft_phi_loc(this%gsa%CFt2(:,:,nR), F, 1)
               this%hsa%CFt2_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
               call fft_phi_loc(this%gsa%CFp2(:,:,nR), F, 1)
               this%hsa%CFp2_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
               call fft_phi_loc(this%gsa%dtVr(:,:,nR), F, 1)
               this%hsa%dtVr_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
               call fft_phi_loc(this%gsa%dtVt(:,:,nR), F, 1)
               this%hsa%dtVt_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
               call fft_phi_loc(this%gsa%dtVp(:,:,nR), F, 1)
               this%hsa%dtVp_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
               if ( l_conv_nl ) then
                  call fft_phi_loc(this%gsa%Advt2(:,:,nR), F, 1)
                  this%hsa%Advt2_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
                  call fft_phi_loc(this%gsa%Advp2(:,:,nR), F, 1)
                  this%hsa%Advp2_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
               end if
               if ( l_adv_curl ) then
                  call fft_phi_loc(this%gsa%dpkindrc(:,:,nR), F, 1)
                  this%hsa%dpkindr_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
               end if
               if ( l_mag_nl .and. nR>n_r_LCR ) then
                  call fft_phi_loc(this%gsa%LFt2(:,:,nR), F, 1)
                  this%hsa%LFt2_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
                  call fft_phi_loc(this%gsa%LFp2(:,:,nR), F, 1)
                  this%hsa%LFp2_Thloc(1:n_m_max,:,nR)=F(1:n_m_max,:)
               end if

         end if

      end do

   end subroutine fft_grid_to_hyb_loop
!-----------------------------------------------------------------------------------
end module rIter_split
