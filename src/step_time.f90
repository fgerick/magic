#include "perflib_preproc.cpp"
module step_time_mod

#ifdef WITH_LIKWID
#include "likwid_f90.h"
#endif

   use iso_fortran_env, only: output_unit
   use fields
   use fieldsLast
   use parallel_mod
   use precision_mod
   use constants, only: zero, one, half
!    use truncation, only: lm_max, n_lm_loc, n_mlo_loc, fd_order, n_r_max,   &
!        &                 nRstart, nRstop, nRstartMag, nRstopMag, n_r_icb,  &
!        &                 n_r_cmb, n_lmP_loc, fd_order_bound
   use truncation  ! DELETEME!!!!!
   use num_param, only: n_time_steps, run_time_limit, tEnd, dtMax, &
       &                dtMin, tScale, dct_counter, nl_counter,    &
       &                solve_counter, lm2phy_counter, td_counter, &
       &                phy2lm_counter, nl_counter, f_exp_counter
   use radial_der, only: get_dr_Rloc, get_ddr_Rloc
   use radial_functions, only: rscheme_oc
   use logic, only: l_mag, l_mag_LF, l_dtB, l_RMS, l_hel, l_TO,        &
       &            l_TOmovie, l_r_field, l_cmb_field, l_HTmovie,      &
       &            l_DTrMagSpec, lVerbose, l_b_nl_icb, l_par,         &
       &            l_b_nl_cmb, l_FluxProfs, l_ViscBcCalc, l_perpPar,  &
       &            l_HT, l_dtBmovie, l_heat, l_conv, l_movie,         &
       &            l_runTimeLimit, l_save_out, l_bridge_step,         &
       &            l_dt_cmb_field, l_chemical_conv, l_mag_kin,        &
       &            l_power, l_double_curl, l_PressGraph, l_probe,     &
       &            l_AB1, l_finite_diff, l_cond_ic, l_single_matrix,  &
       &            l_packed_transp
   use init_fields, only: omega_ic1, omega_ma1
   use movie_data, only: t_movieS
   use radialLoop, only: radialLoopG
   use LMLoop_mod, only: LMLoop, finish_explicit_assembly, assemble_stage, &
       &                 finish_explicit_assembly_Rdist
   use signals_mod, only: initialize_signals, check_signals
   use graphOut_mod, only: open_graph_file, close_graph_file
   use output_data, only: tag, n_graph_step, n_graphs, n_t_graph, t_graph, &
       &                  n_spec_step, n_specs, n_t_spec, t_spec,          &
       &                  n_movie_step, n_movie_frames, n_t_movie, t_movie,&
       &                  n_TOmovie_step, n_TOmovie_frames, n_t_TOmovie,   &
       &                  t_TOmovie, n_pot_step, n_pots, n_t_pot, t_pot,   &
       &                  n_rst_step, n_rsts, n_t_rst, t_rst, n_stores,    &
       &                  n_log_step, n_logs, n_t_log, t_log, n_cmb_step,  &
       &                  n_cmbs, n_t_cmb, t_cmb, n_r_field_step,          &
       &                  n_r_fields, n_t_r_field, t_r_field, n_TO_step,   &
       &                  n_TOs, n_t_TO, t_TO, n_probe_step, n_probe_out,  &
       &                  n_t_probe, t_probe, log_file, n_log_file,        &
       &                  n_time_hits
   use updateB_mod, only: get_mag_rhs_imp, get_mag_ic_rhs_imp
   use updateWP_mod, only: get_pol_rhs_imp
   use updateWPS_mod, only: get_single_rhs_imp
   use updateS_mod, only: get_entropy_rhs_imp
   use updateXI_mod, only: get_comp_rhs_imp
   use updateZ_mod, only: get_tor_rhs_imp, get_rot_rates
   use output_mod, only: output
   use time_schemes, only: type_tscheme
   use useful, only: l_correct_step, logWrite
   use communications, only: lo2r_field, lo2r_s, lo2r_press, lo2r_one, &
       &                     lo2r_flow, lo2r_xi,  r2lo_flow, r2lo_one, &
       &                     r2lo_s, r2lo_xi,r2lo_field
   use courant_mod, only: dt_courant
   use nonlinear_bcs, only: get_b_nl_bcs
   use timing ! Everything is needed
   use LMmapping, only: map_mlo
   use communications, only: gather_Flm !@> TODO: DELETE-MEEEEE

   implicit none

   private

   public :: initialize_step_time, step_time

contains

   subroutine initialize_step_time()

      call initialize_signals()

   end subroutine initialize_step_time
!-------------------------------------------------------------------------------
   subroutine step_time(time, tscheme, n_time_step, run_time_start)
      !
      !  This subroutine performs the actual time-stepping.
      !

      !-- Input from initialization:
      !   time and n_time_step updated and returned to magic.f
      real(cp),            intent(inout) :: time
      class(type_tscheme), intent(inout) :: tscheme
      integer,             intent(inout) :: n_time_step
      type(timer_type),    intent(in) :: run_time_start

      !--- Local variables:

      !--- Logicals controlling output/calculation:
      logical :: l_graph          !
      logical :: l_spectrum
      logical :: l_store          ! Store output in restart file
      logical :: l_new_rst_file   ! Use new rst file
      logical :: l_log            ! Log output
      logical :: l_stop_time      ! Stop time stepping
      logical :: l_frame          ! Movie frame output
      logical :: lTOframe         ! TO movie frame output
      logical :: l_cmb            ! Store set of b at CMB
      logical :: l_r              ! Store coeff at various depths
      logical :: lHelCalc         ! Calculate helicity for output
      logical :: lPowerCalc       ! Calculate viscous heating in the physical space
      logical :: lviscBcCalc      ! Calculate horizontal velocity and (grad T)**2
      logical :: lFluxProfCalc    ! Calculate radial flux components
      logical :: lPerpParCalc     ! Calculate perpendicular and parallel Ekin
      logical :: lGeosCalc        ! Calculate geos.TAG outputs
      logical :: lTOCalc          ! Calculate TO stuff
      logical :: lTONext,lTONext2 ! TO stuff for next steps
      logical :: lTOframeNext,lTOframeNext2
      logical :: l_logNext, l_pot
      logical :: lRmsCalc,lRmsNext, l_pure, l_mat_time
      logical :: lPressCalc,lPressNext
      logical :: lMat, lMatNext   ! update matrices
      logical :: l_probe_out      ! Sensor output

      !-- Timers:
      type(timer_type) :: rLoop_counter, lmLoop_counter, comm_counter
      type(timer_type) :: mat_counter, tot_counter, io_counter, pure_counter
      real(cp) :: run_time_passed, dt_new

      !--- Counter:
      integer :: n_frame          ! No. of movie frames
      integer :: n_cmb_sets       ! No. of stored sets of b at CMB
      integer :: n_stage

      !--- Stuff needed to construct output files:
      character(len=255) :: message

      !--- Courant criteria/diagnosis:
      real(cp) :: dtr, dth, tTot
      !-- Saves values for time step
      real(cp) :: dtrkc_Rloc(nRstart:nRstop), dthkc_Rloc(nRstart:nRstop)

      !--- Explicit part of time stepping partly calculated in radialLoopG and
      !    passed to LMLoop where the time step is preformed.
      !    Note that the respective arrays for the changes in inner-core
      !    magnetic field are calculated in updateB and are only
      !    needed there.

      !--- Lorentz torques:
      real(cp) :: lorentz_torque_ma,lorentz_torque_ic

      !-- Arrays for outMisc.f90 and outPar.f90
      real(cp) :: HelASr_Rloc(2,nRstart:nRstop),Hel2ASr_Rloc(2,nRstart:nRstop)
      real(cp) :: HelnaASr_Rloc(2,nRstart:nRstop),Helna2ASr_Rloc(2,nRstart:nRstop)
      real(cp) :: viscAS_Rloc(nRstart:nRstop), uhASr_Rloc(nRstart:nRstop)
      real(cp) :: duhASr_Rloc(nRstart:nRstop), gradsASr_Rloc(nRstart:nRstop)
      real(cp) :: fconvASr_Rloc(nRstart:nRstop), fkinASr_Rloc(nRstart:nRstop)
      real(cp) :: fviscASr_Rloc(nRstart:nRstop), HelEAASr_Rloc(nRstart:nRstop)
      real(cp) :: fpoynASr_Rloc(nRstartMag:nRstopMag)
      real(cp) :: fresASr_Rloc(nRstartMag:nRstopMag)
      real(cp) :: EperpASr_Rloc(nRstart:nRstop), EparASr_Rloc(nRstart:nRstop)
      real(cp) :: EperpaxiASr_Rloc(nRstart:nRstop), EparaxiASr_Rloc(nRstart:nRstop)

      !--- Nonlinear magnetic boundary conditions needed in s_updateB.f :
      complex(cp) :: br_vt_lm_cmb_dist(n_lmP_loc)    ! product br*vt at CMB
      complex(cp) :: br_vp_lm_cmb_dist(n_lmP_loc)    ! product br*vp at CMB
      complex(cp) :: br_vt_lm_icb_dist(n_lmP_loc)    ! product br*vt at ICB
      complex(cp) :: br_vp_lm_icb_dist(n_lmP_loc)    ! product br*vp at ICB
      
      complex(cp) :: b_nl_cmb(lm_max)         ! nonlinear bc for b at CMB
      complex(cp) :: aj_nl_cmb(lm_max)        ! nonlinear bc for aj at CMB
      complex(cp) :: aj_nl_icb(lm_max)        ! nonlinear bc for dr aj at ICB
      complex(cp) :: b_nl_cmb_dist(n_lm_loc)  ! nonlinear bc for b at CMB
      complex(cp) :: aj_nl_cmb_dist(n_lm_loc) ! nonlinear bc for aj at CMB
      complex(cp) :: aj_nl_icb_dist(n_lm_loc) ! nonlinear bc for dr aj at ICB

      !--- Various stuff for time control:
      real(cp) :: timeLast, timeStage, dtLast
      integer :: n_time_steps_go
      logical :: l_finish_exp_early, l_last_RMS
      logical :: l_new_dt         ! causes call of matbuild !
      integer :: nPercent         ! percentage of finished time stepping
      real(cp) :: tenth_n_time_steps

      !-- Interupt procedure:
      integer :: signals(5)
      integer :: n_stop_signal     ! =1 causes run to stop
      integer :: n_graph_signal    ! =1 causes output of graphic file
      integer :: n_rst_signal      ! =1 causes output of rst file
      integer :: n_spec_signal     ! =1 causes output of a spec file
      integer :: n_pot_signal      ! =1 causes output for pot files
      
      if ( lVerbose ) write(output_unit,'(/,'' ! STARTING STEP_TIME !'')')

      run_time_passed=0.0_cp
      l_log       =.false.
      l_last_RMS  = l_RMS
      l_stop_time =.false.
      l_new_dt    =.true.   ! Invokes calculation of t-step matrices
      lMatNext    =.true.
      timeLast    =time
      timeStage   =time

      l_finish_exp_early = ( l_finite_diff .and. rscheme_oc%order==2 .and. &
      &                      rscheme_oc%order_boundary==2 )

      tenth_n_time_steps=real(n_time_steps,kind=cp)/10.0_cp
      nPercent=9

      !---- Set Lorentz torques to zero:
      lorentz_torque_ic=0.0_cp
      lorentz_torque_ma=0.0_cp

      !---- Counter for output files/sets:
      n_frame   =0    ! No. of movie frames
      n_cmb_sets=0    ! No. of store dt_b sets at CMB

      !---- Prepare signalling via file signal
      signals=0
      n_stop_signal =0     ! Stop signal returned to calling program
      n_graph_signal=0     ! Graph signal returned to calling program
      n_spec_signal=0      ! Spec signal
      n_rst_signal=0       ! Rst signal
      n_pot_signal=0       ! Potential file signal

      !-- STARTING THE TIME STEPPING LOOP:
      if ( l_master_rank ) then
         write(output_unit,*)
         write(output_unit,*) '! Starting time integration!'
      end if
      call comm_counter%initialize()
      call rLoop_counter%initialize()
      call lmLoop_counter%initialize()
      call mat_counter%initialize()
      call tot_counter%initialize()
      call pure_counter%initialize()
      call io_counter%initialize()

      !!!!! Time loop starts !!!!!!
      if ( n_time_steps == 1 ) then
         n_time_steps_go=1 ! Output only, for example G-file/movie etc.
      else if ( n_time_steps == 2 ) then
         n_time_steps_go=2 !
      else
         n_time_steps_go=n_time_steps+1  ! Last time step for output only !
      end if
      
#ifdef WITH_MPI
      call MPI_Barrier(comm_r,ierr)
#endif

      
      !LIKWID_ON('tloop')
      PERFON('tloop')
      outer: do n_time_step=1,n_time_steps_go

         if ( lVerbose ) then
            write(output_unit,*)
            write(output_unit,*) '! Starting time step ',n_time_step
         end if

         !-- Start time counters
         call mat_counter%start_count()
         call tot_counter%start_count()
         call pure_counter%start_count()
         l_pure=.false.
         l_mat_time=.false.

#ifdef WITH_MPI
         ! Broadcast omega_ic and omega_ma
         call MPI_Bcast(omega_ic,1,MPI_DEF_REAL,map_mlo%ml2rnk(0,1),MPI_COMM_WORLD,ierr)
         call MPI_Bcast(omega_ma,1,MPI_DEF_REAL,map_mlo%ml2rnk(0,1),MPI_COMM_WORLD,ierr)
#endif

         !----------------
         !-- This handling of the signal files is quite expensive
         !-- as the file can be read only on one coord_r and the result
         !-- must be distributed to all other ranks.
         !----------------
         call check_signals(run_time_passed, signals)
         n_stop_signal =signals(1)
         n_graph_signal=signals(2)
         n_rst_signal  =signals(3)
         n_spec_signal =signals(4)
         n_pot_signal  =signals(5)

         !--- Various reasons to stop the time integration:
         if ( l_runTimeLimit ) then
            tTot = tot_counter%tTot+run_time_start%tTot
#ifdef WITH_MPI
            call MPI_Allreduce(MPI_IN_PLACE, tTot, 1, MPI_DEF_REAL, MPI_MAX, &
                 &             comm_r, ierr)
#endif
            if ( tTot > run_time_limit ) then
               if ( .not. l_last_RMS ) then
                  write(message,'("! Run time limit exeeded !")')
                  call logWrite(message)
               end if
               l_stop_time=.true.
            end if

         end if
         !-- Handle an extra iteration in case RMS outputs are requested
         if ( (n_stop_signal > 0) .or. (l_RMS .and. (.not. l_last_RMS)) ) then
            l_stop_time=.true.   ! last time step !
         end if
         if ( n_time_step == n_time_steps_go ) then
            l_stop_time=.true.   ! last time step !
            l_last_RMS =.false.
         end if

         !--- Another reasons to stop the time integration:
         if ( time >= tEND .and. tEND /= 0.0_cp ) l_stop_time=.true.

         !-- Checking logic for output:
         l_graph= l_correct_step(n_time_step-1,time,timeLast,n_time_steps,       &
         &                       n_graph_step,n_graphs,n_t_graph,t_graph,0) .or. &
         &                  n_graph_signal == 1
         n_graph_signal=0   ! reset interrupt signal !
         l_spectrum=                                                             &
         &              l_correct_step(n_time_step-1,time,timeLast,n_time_steps, &
         &                n_spec_step,n_specs,n_t_spec,t_spec,0) .or.            &
         &                n_spec_signal == 1
         l_frame= l_movie .and. (                                                &
         &             l_correct_step(n_time_step-1,time,timeLast,n_time_steps,  &
         &             n_movie_step,n_movie_frames,n_t_movie,t_movie,0) .or.     &
         &                   n_time_steps_go == 1 )
         if ( l_mag .or. l_mag_LF ) then
            l_dtB=( l_frame .and. l_dtBmovie ) .or.         &
            &                   ( l_log .and. l_DTrMagSpec )
         end if

         lTOframe=l_TOmovie .and.                                                &
         &          l_correct_step(n_time_step-1,time,timeLast,n_time_steps,     &
         &          n_TOmovie_step,n_TOmovie_frames,n_t_TOmovie,t_TOmovie,0)

         l_probe_out=l_probe .and.                                               &
         &          l_correct_step(n_time_step-1,time,timeLast,n_time_steps,     &
         &          n_probe_step,n_probe_out,n_t_probe,t_probe,0)

         !-- Potential files
         l_pot= l_correct_step(n_time_step-1,time,timeLast,n_time_steps, &
         &                       n_pot_step,n_pots,n_t_pot,t_pot,0) .or. &
         &                  n_pot_signal == 1
         n_pot_signal=0   ! reset interrupt signal !

         l_new_rst_file=                                                         &
         &             l_correct_step(n_time_step-1,time,timeLast,n_time_steps,  &
         &                            n_rst_step,n_rsts,n_t_rst,t_rst,0) .or.    &
         &             n_rst_signal == 1
         n_rst_signal=0
         l_store= l_new_rst_file .or.                                            &
         &             l_correct_step(n_time_step-1,time,timeLast,n_time_steps,  &
         &                            0,n_stores,0,t_rst,0)

         l_log= l_correct_step(n_time_step-1,time,timeLast,n_time_steps,  &
         &                            n_log_step,n_logs,n_t_log,t_log,0)
         l_cmb= l_cmb_field .and.                                                &
         &             l_correct_step(n_time_step-1,time,timeLast,n_time_steps,  &
         &                            n_cmb_step,n_cmbs,n_t_cmb,t_cmb,0)
         l_r= l_r_field .and.                                                    &
         &             l_correct_step(n_time_step-1,time,timeLast,n_time_steps,  &
         &                            n_r_field_step,n_r_fields,n_t_r_field,     &
         &                            t_r_field,0)
         l_logNext=.false.
         if ( n_time_step+1 <= n_time_steps+1 )                                  &
         &             l_logNext=                                                &
         &             l_correct_step(n_time_step,time+tscheme%dt(1),timeLast,   &
         &                   n_time_steps,n_log_step,n_logs,n_t_log,t_log,0)
         lTOCalc= n_time_step > 2 .and. l_TO .and.                   &
         &               l_correct_step(n_time_step-1,time,timeLast, &
         &               n_time_steps,n_TO_step,n_TOs,n_t_TO,t_TO,0)
         lTOnext     =.false.
         lTOframeNext=.false.
         if ( n_time_step+1 <= n_time_steps+1 ) then
            lTONext= l_TO .and.                                            &
            &                l_correct_step(n_time_step,time+tscheme%dt(1),&
            &                timeLast,n_time_steps,n_TO_step,n_TOs,n_t_TO,t_TO,0)
            lTOframeNext= l_TOmovie .and.                                   &
            &                l_correct_step(n_time_step,time+tscheme%dt(1), &
            &                timeLast,n_time_steps,n_TOmovie_step,          &
            &                n_TOmovie_frames,n_t_TOmovie,t_TOmovie,0)
         end if
         lTONext      =lTOnext.or.lTOframeNext
         lTONext2     =.false.
         lTOframeNext2=.false.
         if ( n_time_step+2 <= n_time_steps+1 ) then
            lTONext2= l_TO .and.                                                 &
            &                l_correct_step(n_time_step+1,time+2*tscheme%dt(1),  &
            &                                timeLast,n_time_steps,n_TO_step,    &
            &                                            n_TOs,n_t_TO,t_TO,0)
            lTOframeNext2= l_TOmovie .and.                                      &
            &                l_correct_step(n_time_step+1,time+2*tscheme%dt(1), &
            &                             timeLast,n_time_steps,n_TOmovie_step, &
            &                       n_TOmovie_frames,n_t_TOmovie,t_TOmovie,0)
         end if
         lTONext2=lTOnext2.or.lTOframeNext2

         lRmsCalc=(l_RMS .and. l_log .and. (n_time_step > 1)) .or. &
         &        (l_RMS .and. l_stop_time)
         if ( l_mag .or. l_mag_LF ) l_dtB = l_dtB .or. lRmsCalc
         lRmsNext=l_RMS .and. l_logNext ! Used for storing in update routines !

         if ( n_time_step == 1 ) l_log=.true.

         !-- Compute one more iteration to properly terminate computations of
         !-- viscosity and pressure in the FD setup
         if ( l_last_RMS .and. l_stop_time ) then
            lRmsNext   =.true.
            l_logNext  =.true.
            l_last_RMS =.false.
            lRmsCalc   =.false.
            l_dtB      =.false.
            l_stop_time=.false.
         end if

         if ( l_stop_time ) then                  ! Programm stopped by kill -30
            l_new_rst_file=.true.                 ! Write rst-file and some
            if ( n_stores > 0 ) l_store=.true.    ! diagnostics before dying !
            l_log=.true.
            lRmsNext=.false.
            if ( n_specs > 0 ) l_spectrum=.true.
         end if

         lHelCalc     =l_hel        .and. l_log
         lPowerCalc   =l_power      .and. l_log
         lPerpParCalc =l_perpPar    .and. l_log
         lGeosCalc    =l_par        .and. l_log
         lFluxProfCalc=l_FluxProfs  .and. l_log
         lViscBcCalc  =l_ViscBcCalc .and. l_log

         l_HT  = (l_frame .and. l_movie) .or. lViscBcCalc
         lPressCalc=lRmsCalc .or. ( l_PressGraph .and. l_graph )  &
         &            .or. lFluxProfCalc
         lPressNext=( l_RMS .or. l_FluxProfs ) .and. l_logNext

         if ( l_graph ) call open_graph_file(n_time_step, time)

         tscheme%istage = 1

         do n_stage=1,tscheme%nstages

            !--- Now the real work starts with the radial loop that calculates
            !    the nonlinear terms:
            if ( lVerbose ) then
               write(output_unit,*)
               write(output_unit,*) '! Starting radial loop!'
            end if

            !------------------------
            !-- Storage or special calculatons computed in radial loop need to be
            !-- only done on the first sub-stage
            !------------------------
            l_graph       = l_graph       .and. (tscheme%istage==1)
            l_frame       = l_frame       .and. (tscheme%istage==1)
            lTOCalc       = lTOCalc       .and. (tscheme%istage==1)
            lTONext       = lTONext       .and. (tscheme%istage==1)
            lTONext2      = lTONext2      .and. (tscheme%istage==1)
            lHelCalc      = lHelCalc      .and. (tscheme%istage==1)
            lPowerCalc    = lPowerCalc    .and. (tscheme%istage==1)
            lRmsCalc      = lRmsCalc      .and. (tscheme%istage==1)
            lPressCalc    = lPressCalc    .and. (tscheme%istage==1)
            lViscBcCalc   = lViscBcCalc   .and. (tscheme%istage==1)
            lFluxProfCalc = lFluxProfCalc .and. (tscheme%istage==1)
            lPerpParCalc  = lPerpParCalc  .and. (tscheme%istage==1)
            lGeosCalc     = lGeosCalc     .and. (tscheme%istage==1)
            l_probe_out   = l_probe_out   .and. (tscheme%istage==1)

            if ( tscheme%l_exp_calc(n_stage) ) then

               !----------------
               !- Mloc -> Rloc transposes
               !----------------
               call transp_LMdist_to_Rdist(comm_counter, l_finish_exp_early, &
                    &                      lPressCalc,l_HT)

               !---------------
               !- Radial loop
               !---------------
               call rLoop_counter%start_count()
               PERFON('rloop')
               call radialLoopG(l_graph, l_frame,time,timeStage,tscheme,           &
                    &           dtLast,lTOCalc,lTONext,lTONext2,lHelCalc,          &
                    &           lPowerCalc,lRmsCalc,lPressCalc,lPressNext,         &
                    &           lViscBcCalc,lFluxProfCalc,lperpParCalc,lGeosCalc,  &
                    &           l_probe_out,dsdt_Rdist,dwdt_Rdist,dzdt_Rdist,      &
                    &           dpdt_Rdist,dxidt_Rdist,dbdt_Rdist,djdt_Rdist,      &
                    &           dVxVhLM_Rdist,dVxBhLM_Rdist,dVSrLM_Rdist,          &
                    &           dVXirLM_Rdist,lorentz_torque_ic,lorentz_torque_ma, &
                    &           br_vt_lm_cmb_dist,br_vp_lm_cmb_dist,               &
                    &           br_vt_lm_icb_dist,br_vp_lm_icb_dist,HelASr_Rloc,   &
                    &           Hel2ASr_Rloc,HelnaASr_Rloc,Helna2ASr_Rloc,         &
                    &           HelEAASr_Rloc,viscAS_Rloc,uhASr_Rloc,duhASr_Rloc,  &
                    &           gradsASr_Rloc,fconvASr_Rloc,fkinASr_Rloc,          &
                    &           fviscASr_Rloc,fpoynASr_Rloc,fresASr_Rloc,          &
                    &           EperpASr_Rloc,EparASr_Rloc,EperpaxiASr_Rloc,       &
                    &           EparaxiASr_Rloc,dtrkc_Rloc,dthkc_Rloc)
               PERFOFF
               call rLoop_counter%stop_count()
               
               if ( lVerbose ) write(output_unit,*) '! r-loop finished!'

#ifdef WITH_MPI
               ! ------------------
               ! also exchange the lorentz_torques which are only 
               ! set at the boundary points  but are needed on all processes.
               !@>TODO: there is an allreduce inside of get_lorentz_torque, maybe 
               !        this part can be done there already with a single 
               !        call to mpi, relieving this one here
               ! ------------------
               call MPI_Bcast(lorentz_torque_ic,1,MPI_DEF_REAL,n_ranks_r-1,comm_r, &
                    &         ierr)
               call MPI_Bcast(lorentz_torque_ma,1,MPI_DEF_REAL,0,comm_r,ierr)
#endif

               !---------------
               ! Finish assembing the explicit terms
               !---------------
               if ( l_finish_exp_early ) then
                  call finish_explicit_assembly_Rdist(omega_ic,w_Rdist,b_ic_LMdist,   &
                       &                      aj_ic_LMdist,dVSrLM_Rdist,dVXirLM_Rdist,&
                       &                      dVxVhLM_Rdist,dVxBhLM_Rdist,            &
                       &                      lorentz_torque_ma,lorentz_torque_ic,    &
                       &                      dsdt_Rdist, dxidt_Rdist, dwdt_Rdist,    &
                       &                      djdt_Rdist, dbdt_ic_dist, djdt_ic_dist, &
                       &                      domega_ma_dt, domega_ic_dt,             &
                       &                      lorentz_torque_ma_dt,                   &
                       &                      lorentz_torque_ic_dt, tscheme)
               end if

               !----------------
               !-- Rloc to Mloc transposes
               !----------------
               call transp_Rdist_to_LMdist(comm_counter,tscheme%istage, &
                    &                      l_finish_exp_early, lPressNext)


               !------ Nonlinear magnetic boundary conditions:
               !       For stress-free conducting boundaries
               
               if ( l_b_nl_cmb .and. (nRStart <= n_r_cmb) ) then
                  call get_b_nl_bcs('CMB', br_vt_lm_cmb_dist,br_vp_lm_cmb_dist,   &
                       &            b_nl_cmb_dist,aj_nl_cmb_dist)
                  !@> TODO: still gather those or not ???
                  call gather_Flm(b_nl_cmb_dist, b_nl_cmb)
                  call gather_Flm(aj_nl_cmb_dist, aj_nl_cmb)
                  b_nl_cmb(1) =zero
                  aj_nl_cmb(1)=zero
               end if
               !-- Replace by scatter from rank to lo (and in updateB accordingly)
               if ( l_b_nl_cmb ) then
#ifdef WITH_MPI
                  call MPI_Bcast(b_nl_cmb,lm_max,MPI_DEF_COMPLEX,0,comm_r,ierr)
                  call MPI_Bcast(aj_nl_cmb,lm_max,MPI_DEF_COMPLEX,0,comm_r,ierr)
#endif
               end if
               if ( l_b_nl_icb .and. (nRstop >= n_r_icb) ) then
                  call get_b_nl_bcs('ICB',br_vt_lm_icb_dist,br_vp_lm_icb_dist,    &
                       &            b_nl_cmb_dist,aj_nl_icb_dist)
                  call gather_Flm(aj_nl_icb_dist, aj_nl_icb)
                  aj_nl_icb(1)=zero
               end if
               if ( l_b_nl_icb ) then
#ifdef WITH_MPI
                  call MPI_Bcast(aj_nl_icb,lm_max,MPI_DEF_COMPLEX,n_ranks_r-1, &
                       &         comm_r,ierr)
#endif
               end if
               

               !---------------
               ! Finish assembing the explicit terms
               !---------------
               call lmLoop_counter%start_count()
               PERFON('lmloop')
               if ( .not. l_finish_exp_early ) then
                  call f_exp_counter%start_count()
                  call finish_explicit_assembly(omega_ic,w_LMdist,b_ic_LMdist,        &
                       &                        aj_ic_LMdist,                         &
                       &                        dVSrLM_LMdist(:,:,tscheme%istage),    &
                       &                        dVXirLM_LMdist(:,:,tscheme%istage),   &
                       &                        dVxVhLM_LMdist(:,:,tscheme%istage),   &
                       &                        dVxBhLM_LMdist(:,:,tscheme%istage),   &
                       &                        lorentz_torque_ma,lorentz_torque_ic,  &
                       &                        dsdt_dist, dxidt_dist, dwdt_dist,     &
                       &                        djdt_dist, dbdt_ic_dist,              &
                       &                        djdt_ic_dist, domega_ma_dt,           &
                       &                        domega_ic_dt, lorentz_torque_ma_dt,   &
                       &                        lorentz_torque_ic_dt, tscheme)
                  call f_exp_counter%stop_count()
               end if
               PERFOFF
               call lmLoop_counter%stop_count(l_increment=.false.)
            end if

            !------------
            !--- Output before update of fields in LMLoop:
            !------------
            if ( tscheme%istage == 1 ) then
               if ( lVerbose ) write(output_unit,*) "! start output"

               if ( l_cmb .and. l_dt_cmb_field ) then
                  dbdt_CMB_LMdist(:)=dbdt_dist%expl(:,n_r_cmb,tscheme%istage)
               end if

               if ( lVerbose ) write(output_unit,*) "! start real output"
               call io_counter%start_count()
               call output(time,tscheme,n_time_step,l_stop_time,l_pot,l_log,      &
                    &      l_graph,lRmsCalc,l_store,l_new_rst_file,               &
                    &      l_spectrum,lTOCalc,lTOframe,                           &
                    &      l_frame,n_frame,l_cmb,n_cmb_sets,l_r,                  &
                    &      lorentz_torque_ic,lorentz_torque_ma,dbdt_CMB_LMdist,   &
                    &      HelASr_Rloc,Hel2ASr_Rloc,HelnaASr_Rloc,Helna2ASr_Rloc, &
                    &      HelEAASr_Rloc,viscAS_Rloc,uhASr_Rloc,duhASr_Rloc,      &
                    &      gradsASr_Rloc,fconvASr_Rloc,fkinASr_Rloc,fviscASr_Rloc,&
                    &      fpoynASr_Rloc,fresASr_Rloc,EperpASr_Rloc,EparASr_Rloc, &
                    &      EperpaxiASr_Rloc,EparaxiASr_Rloc)
               call io_counter%stop_count()
               if ( lVerbose ) write(output_unit,*) "! output finished"

               if ( l_graph ) call close_graph_file()

               !----- Finish time stepping, the last step is only for output!
               if ( l_stop_time ) exit outer  ! END OF TIME INTEGRATION

               dtLast = tscheme%dt(1) ! Old time step (needed for some TO outputs)

               !---------------------
               !-- Checking Courant criteria, l_new_dt and dt_new are output
               !---------------------
               call dt_courant(dtr,dth,l_new_dt,tscheme%dt(1),dt_new,dtMax, &
                    &          dtrkc_Rloc,dthkc_Rloc,time)

               !--------------------
               !-- Set weight arrays
               !--------------------
               call tscheme%set_dt_array(dt_new,dtMin,time,n_log_file,n_time_step,&
                    &                    l_new_dt)

               !-- Store the old weight factor of matrices
               !-- if it changes because of dt factors moving
               !-- matrix also needs to be rebuilt
               call tscheme%set_weights(lMatNext)

               !----- Advancing time:
               timeLast=time               ! Time of the previous time step
               time    =time+tscheme%dt(1) ! Update time

            end if

            call tscheme%get_time_stage(timeLast, timeStage)

            lMat = lMatNext
            if ( (l_new_dt .or. lMat) .and. (tscheme%istage==1) ) then
               !----- Calculate matrices for new time step if dt /= dtLast
               lMat=.true.
               if ( l_master_rank ) then
                  write(output_unit,'(1p,'' ! Building matrices at time step:'', &
                  &                   i8,ES16.6)') n_time_step,time
               end if
            end if
            lMatNext = .false.

            !-- If the scheme is a multi-step scheme that is not Crank-Nicolson 
            !-- we have to use a different starting scheme
            call start_from_another_scheme(timeLast, l_bridge_step, n_time_step, tscheme)

            !---------------
            !-- LM Loop (update routines)
            !---------------
            if ( (.not. tscheme%l_assembly) .or. (tscheme%istage/=tscheme%nstages) ) then
               if ( lVerbose ) write(output_unit,*) '! starting lm-loop!'
               call lmLoop_counter%start_count()
               PERFON('lmloop')
               call LMLoop(timeStage,time,tscheme,lMat,lRmsNext,lPressNext,       &
                    &      dsdt_dist,dwdt_dist,dzdt_dist,dpdt_dist,dxidt_dist,    &
                    &      dbdt_dist,djdt_dist,dbdt_ic_dist,djdt_ic_dist,         & 
                    &      domega_ma_dt,domega_ic_dt,lorentz_torque_ma_dt,        &
                    &      lorentz_torque_ic_dt,b_nl_cmb,aj_nl_cmb,aj_nl_icb)
               PERFOFF
               if ( lVerbose ) write(output_unit,*) '! lm-loop finished!'

               !-- Timer counters
               call lmLoop_counter%stop_count()
               if ( tscheme%istage == 1 .and. lMat ) l_mat_time=.true.
               if ( tscheme%istage == 1 .and. .not. lMat .and. &
               &    .not. l_log ) l_pure=.true.

               ! Increment current stage
               tscheme%istage = tscheme%istage+1
            end if

         end do

         !----------------------------
         !-- Assembly stage of IMEX-RK (if needed)
         !----------------------------
         if ( tscheme%l_assembly ) then
            call assemble_stage(time, w_LMdist, dw_LMdist, ddw_LMdist, p_LMdist,     &
                 &              dp_LMdist, z_LMdist, dz_LMdist, s_LMdist, ds_LMdist, &
                 &              xi_LMdist, dxi_LMdist, b_LMdist, db_LMdist,          &
                 &              ddb_LMdist, aj_LMdist, dj_LMdist, ddj_LMdist,        &
                 &              b_ic_LMdist, db_ic_LMdist, ddb_ic_LMdist,            &
                 &              aj_ic_LMdist, dj_ic_LMdist, ddj_ic_LMdist, omega_ic, &
                 &              omega_ic1, omega_ma, omega_ma1, dwdt_dist, dzdt_dist,&
                 &              dpdt_dist, dsdt_dist, dxidt_dist, dbdt_dist,         &
                 &              djdt_dist, dbdt_ic_dist, djdt_ic_dist, domega_ic_dt, &
                 &              domega_ma_dt, lorentz_torque_ic_dt,                  &
                 &              lorentz_torque_ma_dt, lPressNext, lRmsNext, tscheme)
         end if

         !-- Update counters
         if ( l_mat_time ) call mat_counter%stop_count()
         if ( l_pure ) call pure_counter%stop_count()
         call tot_counter%stop_count()

         !-----------------------
         !----- Timing and info of advance:
         !-----------------------
         run_time_passed = tot_counter%tTot/real(tot_counter%n_counts,cp)
         if ( real(n_time_step,cp)+tenth_n_time_steps*real(nPercent,cp) >=  &
         &    real(n_time_steps,cp)  .or. n_time_steps < 31 ) then
            write(message,'(" ! Time step finished:",i6)') n_time_step
            call logWrite(message)
            if ( real(n_time_step,cp)+tenth_n_time_steps*real(nPercent,cp) >= &
            &    real(n_time_steps,cp) .and. n_time_steps >= 10 ) then
               write(message,'(" ! This is           :",i3,"%")') (10-nPercent)*10
               call logWrite(message)
               nPercent=nPercent-1
            end if
            !tot_counter%tTtop%
            if ( l_master_rank ) then
               call formatTime(output_unit,' ! Mean wall time for time step:',  &
               &               run_time_passed)
               if ( l_save_out ) then
                  open(newunit=n_log_file, file=log_file, status='unknown', &
                  &    position='append')
               end if
               call formatTime(n_log_file,' ! Mean wall time for time step:', &
               &               run_time_passed)
               if ( l_save_out ) close(n_log_file)
            end if
         end if

      end do outer ! end of time stepping !
      PERFOFF

      !LIKWID_OFF('tloop')
      

      if ( l_movie ) then
         if ( l_master_rank ) then
            if (n_frame > 0) then
               write(output_unit,'(1p,/,/,A,i10,3(/,A,ES16.6))')          &
               &     " !  No of stored movie frames: ",n_frame,           &
               &     " !     starting at time: ",t_movieS(1)*tScale,      &
               &     " !       ending at time: ",t_movieS(n_frame)*tScale,&
               &     " !      with step width: ",(t_movieS(2)-t_movieS(1))*tScale
               if ( l_save_out ) then
                  open(newunit=n_log_file, file=log_file, status='unknown', &
                  &    position='append')
               end if
               write(n_log_file,'(1p,/,/,A,i10,3(/,A,ES16.6))')           &
               &     " !  No of stored movie frames: ",n_frame,           &
               &     " !     starting at time: ",t_movieS(1)*tScale,      &
               &     " !       ending at time: ",t_movieS(n_frame)*tScale,&
               &     " !      with step width: ",(t_movieS(2)-t_movieS(1))*tScale
               if ( l_save_out ) close(n_log_file)
            else
               write(output_unit,'(1p,/,/,A,i10,3(/,A,ES16.6))')  &
               &     " !  No of stored movie frames: ",n_frame,   &
               &     " !     starting at time: ",0.0_cp,          &
               &     " !       ending at time: ",0.0_cp,          &
               &     " !      with step width: ",0.0_cp
               if ( l_save_out ) then
                  open(newunit=n_log_file, file=log_file, status='unknown', &
                  &    position='append')
               end if
               write(n_log_file,'(1p,/,/,A,i10,3(/,A,ES16.6))') &
               &     " !  No of stored movie frames: ",n_frame, &
               &     " !     starting at time: ",0.0_cp,        &
               &     " !       ending at time: ",0.0_cp,        &
               &     " !      with step width: ",0.0_cp
               if ( l_save_out ) close(n_log_file)
            end if
         end if
      end if

      if ( l_cmb_field ) then
         write(message,'(A,i9)') " !  No of stored sets of b at CMB: ",n_cmb_sets
         call logWrite(message)
      end if

      if ( l_master_rank ) then
         write(output_unit,*)
         call logWrite('')
      end if

      if ( l_save_out ) then
         open(newunit=n_log_file, file=log_file, status='unknown', &
         &    position='append')
      end if
      call rLoop_counter%finalize('! Mean wall time for r Loop                 :', &
           &                      n_log_file)
      call phy2lm_counter%finalize('!    - Time taken for Spat->Spec            :',&
           &                       n_log_file)
      call lm2phy_counter%finalize('!    - Time taken for Spec->Spat            :',&
           &                       n_log_file)
      call nl_counter%finalize('!    - Time taken for nonlinear terms       :',&
           &                       n_log_file)
      call td_counter%finalize('!    - Time taken for time derivative terms :',&
           &                       n_log_file)
      call lmLoop_counter%finalize('! Mean wall time for LM Loop                :',&
           &                       n_log_file)
      call f_exp_counter%finalize('!     - Time taken to compute r-der of adv. :', &
           &                      n_log_file)
      call dct_counter%finalize('!     - Time taken for DCTs and r-der       :',   &
           &                    n_log_file)
      call solve_counter%finalize('!     - Time taken for linear solves        :', &
           &                      n_log_file)
      call comm_counter%finalize('! Mean wall time for MPI communications     :',  &
           &                     n_log_file)
      call mat_counter%finalize('! Mean wall time for t-step with matrix calc:',   &
           &                    n_log_file)
      call io_counter%finalize('! Mean wall time for output routine         :',  &
           &                   n_log_file)
      call pure_counter%finalize('! Mean wall time for one pure time step     :', &
           &                     n_log_file)
      call tot_counter%finalize('! Mean wall time for one time step          :', &
           &                    n_log_file)
      if ( l_save_out ) close(n_log_file)

      !-- WORK IS DONE !

   end subroutine step_time
!------------------------------------------------------------------------------
   subroutine start_from_another_scheme(time, l_bridge_step, n_time_step, tscheme)
      !
      ! This subroutine is used to initialize multisteps schemes whenever previous
      ! steps are not known. In that case a CN/AB2 scheme is used to bridge the
      ! missing steps.
      !

      !-- Input variables
      real(cp),            intent(in) :: time
      logical,             intent(in) :: l_bridge_step
      integer,             intent(in) :: n_time_step

      !-- Output variable
      class(type_tscheme), intent(inout) :: tscheme

      !-- If the scheme is a multi-step scheme that is not Crank-Nicolson 
      !-- we have to use a different starting scheme
      if ( l_bridge_step .and. tscheme%time_scheme /= 'CNAB2' .and.  &
           n_time_step <= tscheme%nold-1 .and.                       &
           tscheme%family=='MULTISTEP' ) then

         if ( l_single_matrix ) then
            call get_single_rhs_imp(s_LMdist, ds_LMdist, w_LMdist, dw_LMdist,     &
                 &                  ddw_LMdist, p_LMdist, dp_LMdist, dsdt_dist,   &
                 &                  dwdt_dist, dpdt_dist, tscheme, 1, .true., .false.)
         else
            call get_pol_rhs_imp(s_LMdist, xi_LMdist, w_LMdist, dw_LMdist,   &
                 &               ddw_LMdist, p_LMdist, dp_LMdist, dwdt_dist, &
                 &               dpdt_dist, tscheme, 1, .true., .false.,     &
                 &               .false., work_LMdist)
            if ( l_heat ) call get_entropy_rhs_imp(s_LMdist, ds_LMdist, dsdt_dist, &
            &                                      1, .true.)
         end if

         call get_rot_rates(omega_ma, lorentz_torque_ma_dt%old(1))
         call get_rot_rates(omega_ic, lorentz_torque_ic_dt%old(1))
         call get_tor_rhs_imp(time, z_LMdist, dz_LMdist, dzdt_dist, domega_ma_dt, &
              &               domega_ic_dt, omega_ic, omega_ma, omega_ic1,        &
              &               omega_ma1, tscheme, 1, .true., .false.)

         if ( l_chemical_conv ) call get_comp_rhs_imp(xi_LMdist, dxi_LMdist,  &
                                     &                dxidt_dist, 1, .true.)

         if ( l_mag ) call get_mag_rhs_imp(b_LMdist, db_LMdist, ddb_LMdist,   &
                           &               aj_LMdist, dj_LMdist, ddj_LMdist,  &
                           &               dbdt_dist, djdt_dist, tscheme, 1,  &
                           &               .true., .false.)

         if ( l_cond_ic ) call get_mag_ic_rhs_imp(b_ic_LMdist, db_ic_LMdist,     &
                               &                  ddb_ic_LMdist, aj_ic_LMdist,   &
                               &                  dj_ic_LMdist, ddj_ic_LMdist,   &
                               &                  dbdt_ic_dist, djdt_ic_dist, 1, &
                               &                  .true.)

         call tscheme%bridge_with_cnab2()

      end if

      if ( l_AB1 .and. n_time_step == 1 ) then
         call tscheme%start_with_ab1()
         l_AB1 = .false.
      end if

   end subroutine start_from_another_scheme
!--------------------------------------------------------------------------------
   subroutine transp_LMdist_to_Rdist(comm_counter, l_Rdist, lPressCalc, lHTCalc)
      ! Here now comes the block where the LM distributed fields
      ! are redistributed to Rdist distribution which is needed for 
      ! the radialLoop.

      !-- Input variables
      logical, intent(in) :: l_Rdist, lPressCalc, lHTCalc

      !-- Output variable
      type(timer_type), intent(inout) :: comm_counter
      
      call comm_counter%start_count()
      PERFON('lm2r')
      if ( l_packed_transp ) then
         if ( l_Rdist ) then
            call lo2r_flow%transp_lm2r_dist(flow_LMdist_container, flow_Rdist_container)
            if ( l_heat .and. lHTCalc ) then
               call get_dr_Rloc(s_Rdist, ds_Rdist, n_lm_loc, nRstart, nRstop, n_r_max, &
                    &           rscheme_oc)
            end if
            if ( l_chemical_conv ) call lo2r_one%transp_lm2r_dist(xi_LMdist,xi_Rdist)
            if ( l_conv .or. l_mag_kin ) then
               call get_ddr_Rloc(w_Rdist, dw_Rdist, ddw_Rdist, n_lm_loc, nRstart, nRstop, &
                    &            n_r_max, rscheme_oc)
               call get_dr_Rloc(z_Rdist, dz_Rdist, n_lm_loc, nRstart, nRstop, n_r_max, &
                    &           rscheme_oc)
            end if
            if ( lPressCalc ) then
               call lo2r_one%transp_lm2r_dist(p_LMdist, p_Rdist)
               call get_dr_Rloc(p_Rdist, dp_Rdist, n_lm_loc, nRstart, nRstop, n_r_max, &
                    &           rscheme_oc)
            end if
            if ( l_mag ) then
               call get_ddr_Rloc(b_Rdist, db_Rdist, ddb_Rdist, n_lm_loc, nRstart, nRstop, &
                    &            n_r_max, rscheme_oc)
               call get_dr_Rloc(aj_Rdist, dj_Rdist, n_lm_loc, nRstart, nRstop, n_r_max, &
                    &           rscheme_oc)
            end if
         else
            if ( l_heat ) then
               call lo2r_one%transp_lm2r_dist(s_LMdist, s_Rdist)
               if ( lHTCalc ) call lo2r_one%transp_lm2r_dist(ds_LMdist, ds_Rdist)
            end if
            if ( l_chemical_conv ) call lo2r_one%transp_lm2r_dist(xi_LMdist,xi_Rdist)
            if ( l_conv .or. l_mag_kin ) then
               call lo2r_flow%transp_lm2r_dist(flow_LMdist_container,flow_Rdist_container)
            end if
            if ( lPressCalc ) then
               call lo2r_press%transp_lm2r_dist(press_LMdist_container,press_Rdist_container)
            end if
            if ( l_mag ) then
               call lo2r_field%transp_lm2r_dist(field_LMdist_container,field_Rdist_container)
            end if
         end if
      else
         if ( l_Rdist ) then
            if ( l_heat ) then
               call lo2r_one%transp_lm2r_dist(s_LMdist, s_Rdist)
               if ( lHTCalc ) then
                  call get_dr_Rloc(s_Rdist, ds_Rdist, n_lm_loc, nRstart, nRstop, n_r_max, &
                       &           rscheme_oc)
               end if
            end if
            if ( l_chemical_conv ) call lo2r_one%transp_lm2r_dist(xi_LMdist,xi_Rdist)
            if ( l_conv .or. l_mag_kin ) then
               call lo2r_one%transp_lm2r_dist(w_LMdist, w_Rdist)
               call get_ddr_Rloc(w_Rdist, dw_Rdist, ddw_Rdist, n_lm_loc, nRstart, nRstop, &
                    &            n_r_max, rscheme_oc)
               call lo2r_one%transp_lm2r_dist(z_LMdist, z_Rdist)
               call get_dr_Rloc(z_Rdist, dz_Rdist, n_lm_loc, nRstart, nRstop, n_r_max, &
                    &           rscheme_oc)
            end if
            if ( lPressCalc ) then
               call lo2r_one%transp_lm2r_dist(p_LMdist, p_Rdist)
               call get_dr_Rloc(p_Rdist, dp_Rdist, n_lm_loc, nRstart, nRstop, n_r_max, &
                    &           rscheme_oc)
            end if
            if ( l_mag ) then
               call lo2r_one%transp_lm2r_dist(b_LMdist, b_Rdist)
               call get_ddr_Rloc(b_Rdist, db_Rdist, ddb_Rdist, n_lm_loc, nRstart, nRstop, &
                    &            n_r_max, rscheme_oc)
               call lo2r_one%transp_lm2r_dist(aj_LMdist, aj_Rdist)
               call get_dr_Rloc(aj_Rdist, dj_Rdist, n_lm_loc, nRstart, nRstop, n_r_max, &
                    &           rscheme_oc)
            end if
         else
            if ( l_heat ) then
               call lo2r_one%transp_lm2r_dist(s_LMdist, s_Rdist)
               if ( lHTCalc ) call lo2r_one%transp_lm2r_dist(ds_LMdist, ds_Rdist)
            end if
            if ( l_chemical_conv ) call lo2r_one%transp_lm2r_dist(xi_LMdist,xi_Rdist)
            if ( l_conv .or. l_mag_kin ) then
               call lo2r_one%transp_lm2r_dist(w_LMdist, w_Rdist)
               call lo2r_one%transp_lm2r_dist(dw_LMdist, dw_Rdist)
               call lo2r_one%transp_lm2r_dist(ddw_LMdist, ddw_Rdist)
               call lo2r_one%transp_lm2r_dist(z_LMdist, z_Rdist)
               call lo2r_one%transp_lm2r_dist(dz_LMdist, dz_Rdist)
            end if
            if ( lPressCalc ) then
               call lo2r_one%transp_lm2r_dist(p_LMdist, p_Rdist)
               call lo2r_one%transp_lm2r_dist(dp_LMdist, dp_Rdist)
            end if
            if ( l_mag ) then
               call lo2r_one%transp_lm2r_dist(b_LMdist, b_Rdist)
               call lo2r_one%transp_lm2r_dist(db_LMdist, db_Rdist)
               call lo2r_one%transp_lm2r_dist(ddb_LMdist, ddb_Rdist)
               call lo2r_one%transp_lm2r_dist(aj_LMdist, aj_Rdist)
               call lo2r_one%transp_lm2r_dist(dj_LMdist, dj_Rdist)
            end if
         end if
      end if
      PERFOFF
      call comm_counter%stop_count(l_increment=.false.)

   end subroutine transp_LMdist_to_Rdist
!--------------------------------------------------------------------------------
   subroutine transp_Rdist_to_LMdist(comm_counter, istage, lRdist, lPressNext)
      !
      !- MPI transposition from r-distributed to LM-distributed
      !

      !-- Input variable
      logical, intent(in) :: lRdist
      logical, intent(in) :: lPressNext
      integer, intent(in) :: istage

      !-- Output variable
      type(timer_type), intent(inout) :: comm_counter

      if ( lVerbose ) write(output_unit,*) "! start r2lo redistribution"

      call comm_counter%start_count()
      PERFON('r2lm')
      if ( l_packed_transp ) then
         if ( lRdist ) then
            call r2lo_flow%transp_r2lm_dist(dflowdt_Rdist_container, &
                 &                     dflowdt_LMdist_container(:,:,:,istage))
            if ( l_conv .or. l_mag_kin ) then
               if ( .not. l_double_curl .or. lPressNext ) then
                  call r2lo_one%transp_r2lm_dist(dpdt_Rdist,dpdt_dist%expl(:,:,istage))
               end if
            end if
            if ( l_chemical_conv ) then
               call r2lo_one%transp_r2lm_dist(dxidt_Rdist,dxidt_dist%expl(:,:,istage))
            end if
         else
            if ( l_conv .or. l_mag_kin ) then
               call r2lo_flow%transp_r2lm_dist(dflowdt_Rdist_container,  &
                    &                     dflowdt_LMdist_container(:,:,:,istage))
            end if
            if ( l_heat ) then
               call r2lo_s%transp_r2lm_dist(dsdt_Rdist_container,&
                    &                  dsdt_LMdist_container(:,:,:,istage))
            end if
            if ( l_chemical_conv ) then
               call r2lo_xi%transp_r2lm_dist(dxidt_Rdist_container, &
                    &                   dxidt_LMdist_container(:,:,:,istage))
            end if
            if ( l_mag ) then
               call r2lo_field%transp_r2lm_dist(dbdt_Rdist_container, &
                    &                      dbdt_LMdist_container(:,:,:,istage))
            end if
         end if
      else
         if ( lRdist ) then
            if ( l_conv .or. l_mag_kin ) then
               call r2lo_one%transp_r2lm_dist(dwdt_Rdist,dwdt_dist%expl(:,:,istage))
               call r2lo_one%transp_r2lm_dist(dzdt_Rdist,dzdt_dist%expl(:,:,istage))
               if ( .not. l_double_curl .or. lPressNext ) then
                  call r2lo_one%transp_r2lm_dist(dpdt_Rdist,dpdt_dist%expl(:,:,istage))
               end if
            end if
            if ( l_heat ) call r2lo_one%transp_r2lm_dist(dsdt_Rdist,dsdt_dist%expl(:,:,istage))
            if ( l_chemical_conv ) then
               call r2lo_one%transp_r2lm_dist(dxidt_Rdist,dxidt_dist%expl(:,:,istage))
            end if
            if ( l_mag ) then
               call r2lo_one%transp_r2lm_dist(dbdt_Rdist,dbdt_dist%expl(:,:,istage))
               call r2lo_one%transp_r2lm_dist(djdt_Rdist,djdt_dist%expl(:,:,istage))
            end if
         else
            if ( l_conv .or. l_mag_kin ) then
               call r2lo_one%transp_r2lm_dist(dwdt_Rdist,dwdt_dist%expl(:,:,istage))
               call r2lo_one%transp_r2lm_dist(dzdt_Rdist,dzdt_dist%expl(:,:,istage))
               call r2lo_one%transp_r2lm_dist(dpdt_Rdist,dpdt_dist%expl(:,:,istage))
               if ( l_double_curl ) then
                  call r2lo_one%transp_r2lm_dist(dVxVhLM_Rdist,dVxVhLM_LMdist(:,:,istage))
               end if
            end if
            if ( l_heat ) then
               call r2lo_one%transp_r2lm_dist(dsdt_Rdist,dsdt_dist%expl(:,:,istage))
               call r2lo_one%transp_r2lm_dist(dVSrLM_Rdist,dVSrLM_LMdist(:,:,istage))
            end if
            if ( l_chemical_conv ) then
               call r2lo_one%transp_r2lm_dist(dxidt_Rdist,dxidt_dist%expl(:,:,istage))
               call r2lo_one%transp_r2lm_dist(dVXirLM_Rdist,dVXirLM_LMdist(:,:,istage))
            end if
            if ( l_mag ) then
               call r2lo_one%transp_r2lm_dist(dbdt_Rdist,dbdt_dist%expl(:,:,istage))
               call r2lo_one%transp_r2lm_dist(djdt_Rdist,djdt_dist%expl(:,:,istage))
               call r2lo_one%transp_r2lm_dist(dVxBhLM_Rdist,dVxBhLM_LMdist(:,:,istage))
            end if
         end if
      end if
      PERFOFF
      call comm_counter%stop_count()

      if ( lVerbose ) write(output_unit,*) "! r2lo redistribution finished"

   end subroutine transp_Rdist_to_LMdist
!--------------------------------------------------------------------------------
end module step_time_mod
