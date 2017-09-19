module step_time

   use communications, only: transp_m2r, m2r_fields, transp_r2m, r2m_fields, &
       &                     gather_from_mloc_to_rank0, my_reduce_mean,      &
       &                     scatter_from_rank0_to_mloc
   use fields, only: us_Mloc, us_Rloc, up_Mloc, up_Rloc, temp_Mloc,     &
       &             temp_Rloc, om_Rloc, om_Mloc, psi_Mloc, dtemp_Mloc, &
       &             dom_Mloc
   use fieldsLast, only: dpsidt_Rloc, dtempdt_Rloc,              &
       &                 dVsT_Rloc, dVsT_Mloc, dVsOm_Rloc,       &
       &                 dVsOm_Mloc, dtemp_imp_Mloc, dtemp_exp_Mloc, &
       &                 dpsi_imp_Mloc, dpsi_exp_Mloc, buo_imp_Mloc
   use courant_mod, only: dt_courant
   use blocking, only: nRstart, nRstop
   use constants, only: half, one
   use update_temperature, only: update_temp, get_temp_rhs_imp
   use update_psi, only: update_om, get_psi_rhs_imp
   use rLoop, only: radial_loop
   use namelists, only: n_time_steps, alpha, dtMax, dtMin, l_bridge_step, &
       &                tEND, run_time_requested, n_log_step, n_frames,   &
       &                n_frame_step, n_checkpoints, n_checkpoint_step,   &
       &                n_spec_step, n_specs, l_vphi_balance, l_AB1
   use outputs, only: n_log_file, write_outputs, vp_bal
   use useful, only: logWrite, abortRun, formatTime, l_correct_step
   use time_scheme, only: type_tscheme
   use parallel_mod
   use precision_mod

   implicit none

   private

   public :: time_loop

contains

   subroutine time_loop(time, tscheme)

      !-- Output variables
      real(cp),           intent(inout) :: time
      type(type_tscheme), intent(inout) :: tscheme

      !-- Local variables
      real(cp) :: w1, timeLast
      integer :: n_time_step, n_time_steps_go, n_time_steps_run
      integer :: nPercent
      real(cp) :: tenth_n_time_steps
      character(len=255) :: message
      character(len=4) :: old_scheme

      !-- Courant
      real(cp) :: dtr,dth,dt_new
      real(cp) :: dtr_Rloc(nRstart:nRstop), dth_Rloc(nRstart:nRstop)

      !-- Timings:
      integer :: n_r_loops, n_mpi_comms, n_m_loops, n_m_loops_mat
      integer :: n_io_calls
      real(cp) :: run_time_r_loop, run_time_mpi_comms
      real(cp) :: run_time_m_loop, run_time_m_loop_mat
      real(cp) :: run_time_tot, run_time_io, run_time_passed
      real(cp) :: runStart, runStop, runStartT, runStopT

      logical :: l_new_dt
      logical :: l_rst
      logical :: l_frame
      logical :: l_spec
      logical :: l_log, l_log_next
      logical :: l_vphi_bal_calc, l_vphi_bal_write
      logical :: l_stop_time
      logical :: lMat, lMatNext
      logical :: l_roll_imp

      tenth_n_time_steps=real(n_time_steps,kind=cp)/10.0_cp
      nPercent = 9

      l_new_dt        =.true.
      l_rst           =.false.
      l_frame         =.false.
      l_spec          =.false.
      l_log           =.false.
      l_log_next      =.true.
      l_stop_time     =.false.
      l_vphi_bal_calc =.false.
      l_vphi_bal_write=.false.
      l_roll_imp      =.true.
      lMatNext        =.true.

      !-- Dummy initial timings
      dtr_Rloc(:) = 1e10_cp
      dth_Rloc(:) = 1e10_cp

      n_r_loops     = 0
      n_m_loops     = 0
      n_m_loops_mat = 0
      n_mpi_comms   = 0
      n_io_calls    = 0
      run_time_r_loop     = 0.0_cp
      run_time_m_loop     = 0.0_cp
      run_time_io         = 0.0_cp
      run_time_mpi_comms  = 0.0_cp
      run_time_m_loop_mat = 0.0_cp
      run_time_tot        = 0.0_cp

      !!!!! Time loop starts !!!!!!
      if ( n_time_steps == 1 ) then
         n_time_steps_run=1 ! Output only, for example G-file/movie etc.
      else if ( n_time_steps == 2 ) then
         n_time_steps_run=2 ! 
      else
         n_time_steps_run=n_time_steps+1  ! Last time step for output only !
      end if

      call MPI_Barrier(MPI_COMM_WORLD, ierr)

      n_time_steps_go = 0
      outer: do n_time_step=1,n_time_steps_run

         !-------------------
         !-- MPI transpositions from m-distributed to r-distributed
         !-------------------
         runStartT = MPI_Wtime()
         call transp_m2r(m2r_fields, us_Mloc, us_Rloc)
         call transp_m2r(m2r_fields, up_Mloc, up_Rloc)
         call transp_m2r(m2r_fields, temp_Mloc, temp_Rloc)
         call transp_m2r(m2r_fields, om_Mloc, om_Rloc)
         runStop = MPI_Wtime()
         if (runStop>runStartT) then
            n_mpi_comms  =n_mpi_comms+1
            run_time_mpi_comms=run_time_mpi_comms+(runStop-runStartT)
         end if

         !-------------------
         !-- Determine whether we will need outputs at this time step
         !-------------------
         l_log = l_correct_step(n_time_step-1,timeLast,n_time_steps, &
                 &              n_log_step,0)
         if ( n_time_step+1 <= n_time_steps+1 ) then
            l_log_next = l_correct_step(n_time_step,timeLast,n_time_steps, &
                    &                   n_log_step,0)
         end if
         l_rst = l_correct_step(n_time_step-1,timeLast,n_time_steps, &
                 &              n_checkpoint_step,n_checkpoints)
         l_frame = l_correct_step(n_time_step-1,timeLast,n_time_steps, &
                   &              n_frame_step,n_frames)
         l_spec = l_correct_step(n_time_step-1,timeLast,n_time_steps, &
                   &             n_spec_step,n_specs)
         l_vphi_bal_write = l_log .and. l_vphi_balance
         l_vphi_bal_calc = l_log_next .and. l_vphi_balance

         !-------------------
         !-- Radial loop
         !-------------------
         runStart = MPI_Wtime()
         call radial_loop( us_Rloc, up_Rloc, om_Rloc, temp_Rloc,  &
              &            dtempdt_Rloc, dVsT_Rloc, dpsidt_Rloc,  &
              &            dVsOm_Rloc, dtr_Rloc, dth_Rloc )
         runStop = MPI_Wtime()
         if (runStop>runStart) then
            n_r_loops  =n_r_loops+1
            run_time_r_loop=run_time_r_loop+(runStop-runStart)
         end if

         !------------------
         !-- MPI transpositions from r-distributed to m-distributed
         !------------------
         runStart = MPI_Wtime()
         call transp_r2m(r2m_fields, dtempdt_Rloc, dtemp_exp_Mloc(:,:,1))
         call transp_r2m(r2m_fields, dpsidt_Rloc, dpsi_exp_Mloc(:,:,1))
         call transp_r2m(r2m_fields, dVsT_Rloc, dVsT_Mloc)
         call transp_r2m(r2m_fields, dVsOm_Rloc, dVsOm_Mloc)
         runStop = MPI_Wtime()
         if (runStop>runStart) then
            run_time_mpi_comms=run_time_mpi_comms+(runStop-runStart)
         end if

         !-------------------
         !-- Check whether the run is not getting out of time
         !-------------------
         call MPI_Allreduce(MPI_IN_PLACE,run_time_tot,1,MPI_INTEGER8, &
              &             MPI_MAX,MPI_COMM_WORLD,ierr)
         if ( run_time_tot > run_time_requested ) then
            write(message,'("! Run time limit exeeded !")')
            call logWrite(message, n_log_file)
            l_stop_time=.true.
         end if
         !-- Some reasons to stop the run
         if ( n_time_step == n_time_steps_run ) l_stop_time=.true.
         if ( time > tEND .and. tEND /= 0.0_cp ) l_stop_time=.true.

         if ( n_time_step == 1 ) l_log=.true.

         if ( l_stop_time ) then             
            l_rst=.true.           
            l_log=.true.
         end if

         !-------------------
         !-- Outputs
         !-------------------
         !-- Get time series
         runStart = MPI_Wtime()
         call write_outputs(time, tscheme, n_time_step, l_log, l_rst, l_spec,  &
              &             l_frame, l_vphi_bal_write, l_stop_time, us_Mloc,   &
              &             up_Mloc, om_Mloc, temp_Mloc, dtemp_Mloc,           &
              &             dtemp_exp_Mloc, dtemp_imp_Mloc, dpsi_exp_Mloc,     &
              &             dpsi_imp_Mloc)
         runStop = MPI_Wtime()
         if (runStop>runStart) then
            n_io_calls  =n_io_calls+1
            run_time_io=run_time_io+(runStop-runStart)
         end if

         if ( l_stop_time ) exit outer

         !-------------------
         !------ Checking Courant criteria, l_new_dt and dt_new are output
         !-------------------
         call dt_courant(dtr,dth,l_new_dt,tscheme%dt(1),dt_new,dtMax, &
              &          dtr_Rloc,dth_Rloc)

         call tscheme%set_dt_array(dt_new,dtMin,time,n_log_file,n_time_step, &
              &                    l_new_dt)
         call tscheme%set_weights()

         !----- Advancing time:
         timeLast=time               ! Time of the previous timestep
         time    =time+tscheme%dt(1) ! Update time

         lMat=lMatNext
         if ( l_new_dt .or. lMat ) then
            !----- Calculate matricies for new time step if dt /= dtLast
            lMat=.true.
            if ( rank == 0 ) then
               write(*,'(1p,/,'' ! Building matricies at time step:'',   &
                    &              i8,ES16.6)') n_time_step,time
            end if
         end if

         !-- If the scheme is not Crank-Nicolson we have to use a different scheme
         l_roll_imp = .true.
         lMatNext = .false.
         if ( l_bridge_step .and. tscheme%imp_scheme /= 'CN' .and.  &
              n_time_step == 1 ) then
            if (rank == 0 ) write(*,*) '! Crank-Nicolson for the 1st time-step'

            call get_temp_rhs_imp(temp_Mloc, dtemp_Mloc, tscheme%wimp_lin(2),&
                 &                dtemp_imp_Mloc(:,:,2))
            call get_psi_rhs_imp(us_Mloc, up_Mloc, om_Mloc, dom_Mloc,        &
                 &               tscheme%wimp_lin(2), dpsi_imp_Mloc(:,:,2),  &
                 &               vp_bal, l_vphi_bal_calc)
            old_scheme        =tscheme%imp_scheme
            tscheme%imp_scheme='CN'
            call tscheme%set_weights()
            !-- Since CN has only two coefficients, one has to set the remainings to zero
            tscheme%wimp(3:size(tscheme%wimp))=0.0_cp
            !-- One does not want to roll the implicit part in that case
            l_roll_imp = .false.
            tscheme%imp_scheme=old_scheme
            lMatNext = .true.
         end if

         if ( l_AB1 .and. n_time_step == 1 ) then
            if (rank == 0 ) write(*,*) '! 1st order Adams-Bashforth for 1st time step'
            w1 = one
            tscheme%wexp(1)=one
            tscheme%wexp(2:tscheme%norder_exp)=0.0_cp
            l_AB1 = .false.
         end if

         !--------------------
         !-- M-loop (update routines)
         !--------------------
         runStart = MPI_Wtime()
         !print*, 'dT[old]', sum(abs(dtemp_imp_Mloc(:,:,2)))
         !print*, 'old_T', sum(abs(temp_Mloc))
         call update_temp(us_Mloc, temp_Mloc, dtemp_Mloc, dVsT_Mloc,    &
              &           dtemp_exp_Mloc, dtemp_imp_Mloc, buo_imp_Mloc, &
              &           tscheme, lMat, l_roll_imp, l_log_next)
         !print*, 'new_T', sum(abs(temp_Mloc))
         !print*, 'dT[old]', sum(abs(dtemp_imp_Mloc(:,:,2)))
         !print*, 'dom[old]', sum(abs(dpsi_imp_Mloc(:,:,2)))
         !print*, 'old_om', sum(abs(om_Mloc))
         call update_om(psi_Mloc, om_Mloc, dom_Mloc, us_Mloc, up_Mloc,  &
              &         dVsOm_Mloc, dpsi_exp_Mloc, dpsi_imp_Mloc,       &
              &         buo_imp_Mloc, vp_bal, tscheme, lMat, l_roll_imp,&
              &         l_vphi_bal_calc)
         !print*, 'new_om', sum(abs(om_Mloc))
         !print*, 'dom[old]', sum(abs(dpsi_imp_Mloc(:,:,2)))

         runStop = MPI_Wtime()
         if ( .not. lMat ) then
            if (runStop>runStart) then
               n_m_loops  =n_m_loops+1
               run_time_m_loop=run_time_m_loop+(runStop-runStart)
            end if
         else
            if (runStop>runStart) then
               n_m_loops_mat  =n_m_loops_mat+1
               run_time_m_loop_mat=run_time_m_loop_mat+(runStop-runStart)
            end if
         end if

         !---------------------
         !-- Timings
         !---------------------
         runStopT = MPI_Wtime()
         if (runStop>runStart) then
            run_time_tot=run_time_tot+(runStopT-runStartT)
         end if

         n_time_steps_go = n_time_steps_go+1

         !---------------------
         !-- Info about run advance
         !---------------------
         if ( real(n_time_step,cp)+tenth_n_time_steps*real(nPercent,cp) >=  &
            & real(n_time_steps,cp)  .or. n_time_steps < 31 ) then
            write(message,'(" ! Time step finished:",i6)') n_time_step
            call logWrite(message, n_log_file)

            if ( real(n_time_step,cp)+tenth_n_time_steps*real(nPercent,cp) >= &
               & real(n_time_steps,cp) .and. n_time_steps >= 10 ) then
               write(message,'(" ! This is           :",i3,"%")') (10-nPercent)*10
               call logWrite(message, n_log_file)
               nPercent=nPercent-1
            end if
            run_time_passed=run_time_tot
            run_time_passed = run_time_passed/n_time_steps_go
            if ( rank == 0 ) then
               call formatTime(6,' ! Mean wall time for time step:',  &
               &               run_time_passed)
               call formatTime(n_log_file,' ! Mean wall time for time step:', &
               &               run_time_passed)
            end if

         end if

      end do outer ! end of time stepping !

      !--------------
      !-- Calculate wall time for different part of the code
      !-- and average over the different ranks
      !--------------
      run_time_io        = run_time_io/n_io_calls
      call my_reduce_mean(run_time_io, 0)
      run_time_r_loop    = run_time_r_loop/n_r_loops
      call my_reduce_mean(run_time_r_loop, 0)
      if ( n_m_loops /= 0 ) then
         run_time_m_loop    = run_time_m_loop/n_m_loops
         call my_reduce_mean(run_time_m_loop, 0)
      end if
      if ( n_m_loops_mat /= 0 ) then
         run_time_m_loop_mat= run_time_m_loop_mat/n_m_loops_mat
         call my_reduce_mean(run_time_m_loop_mat, 0)
      end if
      run_time_mpi_comms = run_time_mpi_comms/n_mpi_comms
      call my_reduce_mean(run_time_mpi_comms, 0)
      if ( n_time_steps_go /= 0 ) then
         run_time_tot       = run_time_tot/n_time_steps_go
         call my_reduce_mean(run_time_tot, 0)
      end if

      if ( rank == 0 ) then
         call formatTime(6, &
         &    '! Mean wall time for radial loop            :',run_time_r_loop)
         call formatTime(6, &
         &    '! Mean wall time for pure m loop            :',run_time_m_loop)
         call formatTime(6, &
         &    '! Mean wall time for m loop with matrix calc:',run_time_m_loop_mat)
         call formatTime(6, &
         &    '! Mean wall time for MPI communications     :',run_time_mpi_comms)
         call formatTime(6, &
         &    '! Mean wall time for output writting        :',run_time_io)
         call formatTime(6, &
         &    '! Mean wall time for one time step          :',run_time_tot)

         call formatTime(n_log_file, &
         &    '! Mean wall time for radial loop            :',run_time_r_loop)
         call formatTime(n_log_file,  &
         &    '! Mean wall time for pure m loop            :',run_time_m_loop)
         call formatTime(n_log_file, &
         &    '! Mean wall time for MPI communications     :',run_time_mpi_comms)
         call formatTime(n_log_file, &
         &    '! Mean wall time for m loop with matrix calc:',run_time_m_loop_mat)
         call formatTime(n_log_file, &
         &    '! Mean wall time for output writting        :',run_time_io)
         call formatTime(n_log_file,  &
         &    '! Mean wall time for one time step          :',run_time_tot)
      end if

   end subroutine time_loop

end module step_time
