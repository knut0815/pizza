module update_psi

   use precision_mod
   use parallel_mod
   use mem_alloc, only: bytes_allocated
   use constants, only: one, zero, ci, half
   use outputs, only: vp_bal_type
   use pre_calculations, only: opr, CorFac
   use namelists, only: kbotv, ktopv, alpha, ra
   use radial_functions, only: rscheme, or1, or2, rgrav, beta, dbeta, &
       &                       ekpump, oheight, r_cmb
   use blocking, only: nMstart, nMstop, l_rank_has_m0
   use truncation, only: n_r_max, idx2m, m2idx
   use radial_der, only: get_ddr, get_dr
   use fields, only: work_Mloc
   use algebra, only: cgefa, cgesl, sgefa, rgesl
   use useful, only: abortRun

   implicit none
   
   private

   logical,  allocatable :: lPsimat(:)
   complex(cp), allocatable :: psiMat(:,:,:)
   real(cp), allocatable :: uphiMat(:,:)
   integer,  allocatable :: psiPivot(:,:)
   real(cp), allocatable :: psiMat_fac(:,:,:)
   complex(cp), allocatable :: rhs(:)
   real(cp), allocatable :: rhs_m0(:)

   public :: update_om, initialize_update_om, finalize_update_om, &
   &         get_rhs_om

contains

   subroutine initialize_update_om

      allocate( lPsimat(nMstart:nMstop) )
      lPsimat(:)=.false.
      bytes_allocated = bytes_allocated+(nMstop-nMstart+1)*SIZEOF_LOGICAL

      allocate( psiMat(2*n_r_max, 2*n_r_max, nMstart:nMstop) )
      allocate( psiPivot(2*n_r_max, nMstart:nMstop) )
      allocate( psiMat_fac(2*n_r_max, 2, nMstart:nMstop) )
      allocate( rhs(2*n_r_max), rhs_m0(n_r_max) )

      bytes_allocated = bytes_allocated+(nMstop-nMstart+1)*4*n_r_max*n_r_max* &
      &                 SIZEOF_DEF_COMPLEX+2*n_r_max*(nMstop-nMstart+1)*      &
      &                 SIZEOF_INTEGER+ n_r_max*(3+4*(nMstop-nMstart+1))*     &
      &                 SIZEOF_DEF_REAL

      allocate( uphiMat(n_r_max,n_r_max) )
      bytes_allocated = bytes_allocated+n_r_max*n_r_max*SIZEOF_DEF_REAL

   end subroutine initialize_update_om
!------------------------------------------------------------------------------
   subroutine finalize_update_om

      deallocate( rhs_m0, rhs, psiMat_fac )
      deallocate( lPsimat, psiMat, uphiMat, psiPivot )

   end subroutine finalize_update_om
!------------------------------------------------------------------------------
   subroutine update_om(psi_Mloc, om_Mloc, dom_Mloc, us_Mloc, up_Mloc,    &
              &         t_Mloc, dpsidt_Mloc, dVsOm_Mloc, dpsidtLast_Mloc, &
              &         vp_bal, w1, coex, dt, lMat, l_vphi_bal_calc)

      !-- Input variables
      real(cp),    intent(in) :: w1        ! weight for time step !
      real(cp),    intent(in) :: coex      ! factor depending on alpha
      real(cp),    intent(in) :: dt        ! time step
      logical,     intent(in) :: lMat
      logical,     intent(in) :: l_vphi_bal_calc
      complex(cp), intent(in) :: t_Mloc(nMstart:nMstop, n_r_max)

      !-- Output variables
      complex(cp),       intent(out) :: psi_Mloc(nMstart:nMstop,n_r_max)
      complex(cp),       intent(out) :: om_Mloc(nMstart:nMstop,n_r_max)
      complex(cp),       intent(out) :: dom_Mloc(nMstart:nMstop,n_r_max)
      complex(cp),       intent(out) :: us_Mloc(nMstart:nMstop,n_r_max)
      complex(cp),       intent(out) :: up_Mloc(nMstart:nMstop,n_r_max)
      type(vp_bal_type), intent(inout) :: vp_bal
      complex(cp),       intent(inout) :: dpsidt_Mloc(nMstart:nMstop,n_r_max)
      complex(cp),       intent(inout) :: dVsOm_Mloc(nMstart:nMstop,n_r_max)
      complex(cp),       intent(inout) :: dpsidtLast_Mloc(nMstart:nMstop,n_r_max)

      !-- Local variables
      real(cp) :: w2            ! weight of second time step
      real(cp) ::  uphi0(n_r_max), om0(n_r_max)
      real(cp) :: O_dt
      integer :: n_r, n_m, n_r_out, m

      w2  =one-w1
      O_dt=one/dt

      if ( lMat ) lPsimat(:)=.false.

      !-- Finish calculation of advection
      call get_dr( dVsOm_Mloc, work_Mloc, nMstart, nMstop, n_r_max, &
           &       rscheme, nocopy=.true.)

      !-- Finish calculation of dpsidt
      do n_r=1,n_r_max
         do n_m=nMstart, nMstop
            m = idx2m(n_m)
            if ( m /= 0 ) then
               dpsidt_Mloc(n_m,n_r)=dpsidt_Mloc(n_m,n_r)-   &
               &                    or1(n_r)*work_Mloc(n_m,n_r)
            end if
         end do
      end do

      if ( lMat ) lPsimat(:)=.false.

      do n_m=nMstart,nMstop

         m = idx2m(n_m)

         if ( m == 0 ) then ! Axisymmetric component

            if ( .not. lPsimat(n_m) ) then
               call get_uphiMat(dt, uphiMat(:,:), psiPivot(1:n_r_max,n_m))
               lPsimat(n_m)=.true.
            end if

            rhs_m0(1)       = 0.0_cp
            rhs_m0(n_r_max) = 0.0_cp
            do n_r=2,n_r_max-1
               rhs_m0(n_r)=real(up_Mloc(n_m,n_r),kind=cp)*O_dt  + &
               &          w1*real(dpsidt_Mloc(n_m,n_r),kind=cp) + &
               &          w2*real(dpsidtLast_Mloc(n_m,n_r),kind=cp)
            end do

            if ( l_vphi_bal_calc ) then
               do n_r=1,n_r_max
                  vp_bal%dvpdt(n_r)     =real(up_Mloc(n_m,n_r))*O_dt
                  vp_bal%rey_stress(n_r)=real(dpsidt_Mloc(n_m,n_r))
               end do
            end if

            call rgesl(uphiMat(:,:), n_r_max, n_r_max, psiPivot(1:n_r_max,n_m), &
                 &     rhs_m0(:))

            do n_r_out=1,rscheme%n_max
               uphi0(n_r_out)=rhs_m0(n_r_out)
            end do

         else ! Non-axisymmetric components
         
            if ( .not. lPsimat(n_m) ) then
               call get_psiMat(dt, m, psiMat(:,:,n_m), psiPivot(:,n_m), &
                    &          psiMat_fac(:,:,n_m))
               lPsimat(n_m)=.true.
            end if

            rhs(1)        =zero
            rhs(n_r_max)  =zero
            rhs(n_r_max+1)=zero
            rhs(2*n_r_max)=zero
            do n_r=2,n_r_max-1
               rhs(n_r)=om_Mloc(n_m,n_r)*O_dt       +  &
               &        w1*dpsidt_Mloc(n_m,n_r)     +  &
               &        w2*dpsidtLast_Mloc(n_m,n_r) -  &
               &        alpha*ra*opr*rgrav(n_r)*       &
               &        or1(n_r)*ci*real(m,cp)*t_Mloc(n_m,n_r)
               rhs(n_r+n_r_max)=zero
            end do

            do n_r=1,2*n_r_max
               rhs(n_r) = rhs(n_r)*psiMat_fac(n_r,1,n_m)
            end do
            call cgesl(psiMat(:,:,n_m), 2*n_r_max, 2*n_r_max, psiPivot(:, n_m), &
                 &     rhs(:))
            do n_r=1,2*n_r_max
               rhs(n_r) = rhs(n_r)*psiMat_fac(n_r,2,n_m)
            end do

            do n_r_out=1,rscheme%n_max
               om_Mloc(n_m,n_r_out) =rhs(n_r_out)
               psi_Mloc(n_m,n_r_out)=rhs(n_r_out+n_r_max)
            end do

         end if

      end do

      !-- set cheb modes > rscheme%n_max to zero (dealiazing)
      if ( rscheme%n_max < n_r_max ) then ! fill with zeros !
         do n_r_out=rscheme%n_max+1,n_r_max
            do n_m=nMstart,nMstop
               m = idx2m(n_m)
               if ( m == 0 ) then
                  uphi0(n_r_out)=0.0_cp
               else
                  om_Mloc(n_m,n_r_out) =zero
                  psi_Mloc(n_m,n_r_out)=zero
               end if
            end do
         end do
      end if

      !-- Bring uphi0 to the physical space
      if ( l_rank_has_m0 ) then
         call rscheme%costf1(uphi0, n_r_max)
         call get_dr(uphi0, om0, n_r_max, rscheme)

         if ( l_vphi_bal_calc ) then
            do n_r=1,n_r_max
               vp_bal%dvpdt(n_r)=uphi0(n_r)*O_dt-vp_bal%dvpdt(n_r)
            end do
         end if
      end if

      !-- Bring psi and omega to the physical space
      call rscheme%costf1(psi_Mloc, nMstart, nMstop, n_r_max)
      call rscheme%costf1(om_Mloc, nMstart, nMstop, n_r_max)

      !-- Get the radial derivative of psi to calculate uphi
      call get_dr(psi_Mloc, work_Mloc, nMstart, nMstop, n_r_max, rscheme)

      do n_r=1,n_r_max
         do n_m=nMstart,nMstop
            m = idx2m(n_m)

            if ( m == 0 ) then
               us_Mloc(n_m,n_r)=0.0_cp
               up_Mloc(n_m,n_r)=uphi0(n_r)
               om_Mloc(n_m,n_r)=om0(n_r)+or1(n_r)*uphi0(n_r)
            else
               us_Mloc(n_m,n_r)=ci*real(m,cp)*or1(n_r)*psi_Mloc(n_m,n_r)
               up_Mloc(n_m,n_r)=-work_Mloc(n_m,n_r)-beta(n_r)*psi_Mloc(n_m,n_r)
            end if
         end do
      end do

      !call get_dr(us_Mloc, work_Mloc, nMstart, nMstop, n_r_max, rscheme)
      !do n_r=1,n_r_max
      !   do n_m=nMstart,nMstop
      !      m = idx2m(n_m)
      !      work_Mloc(n_m,n_r) = work_Mloc(n_m,n_r)+or1(n_r)*us_Mloc(n_m,n_r)+&
      !      &                    ci*m*or1(n_r)*up_Mloc(n_m,n_r)+              &
      !      &                    beta(n_r)*us_Mloc(n_m,n_r)
      !   end do
      !end do
      !print*, 'div=', maxval(abs(work_Mloc(:,2:n_r_max)))

      call get_rhs_om(us_Mloc, up_Mloc, om_Mloc, dom_Mloc, t_Mloc,  &
           &          dpsidt_Mloc, dpsidtLast_Mloc, vp_bal, coex,   &
           &          l_vphi_bal_calc)

   end subroutine update_om
!------------------------------------------------------------------------------
   subroutine get_rhs_om(us_Mloc, up_Mloc, om_Mloc, dom_Mloc, t_Mloc, &
              &          dpsidt_Mloc, dpsidtLast_Mloc, vp_bal, coex,  &
              &          l_vphi_bal_calc)

      !-- Input variables
      complex(cp), intent(in) :: us_Mloc(nMstart:nMstop,n_r_max)
      complex(cp), intent(in) :: up_Mloc(nMstart:nMstop,n_r_max)
      complex(cp), intent(in) :: om_Mloc(nMstart:nMstop,n_r_max)
      complex(cp), intent(in) :: t_Mloc(nMstart:nMstop,n_r_max)
      complex(cp), intent(in) :: dpsidt_Mloc(nMstart:nMstop,n_r_max)
      real(cp),    intent(in) :: coex
      logical,     intent(in) :: l_vphi_bal_calc

      !-- Output variable
      complex(cp),       intent(out) :: dom_Mloc(nMstart:nMstop,n_r_max)
      complex(cp),       intent(out) :: dpsidtLast_Mloc(nMstart:nMstop,n_r_max)
      type(vp_bal_type), intent(inout) :: vp_bal

      !-- Local variables:
      real(cp) :: duphi0(n_r_max), d2uphi0(n_r_max), uphi0(n_r_max)
      integer :: n_r, n_m, m, m0
      real(cp) :: dm2

      call get_ddr(om_Mloc, dom_Mloc, work_Mloc, nMstart, nMstop, &
           &       n_r_max, rscheme)

      m0 = m2idx(0)

      if ( l_rank_has_m0 ) then
         do n_r=1,n_r_max
            uphi0(n_r)=real(up_Mloc(m0, n_r),kind=cp)
         end do
         call get_ddr(uphi0, duphi0, d2uphi0, n_r_max, rscheme)
      end if

      do n_r=1,n_r_max
         do n_m=nMstart,nMstop
            m = idx2m(n_m)
            if ( m == 0 ) then
               dpsidtLast_Mloc(n_m,n_r)=dpsidt_Mloc(n_m,n_r)-    &
               &      coex*(                    d2uphi0(n_r)+    &
               &                       or1(n_r)* duphi0(n_r)-    &
               &       (or2(n_r)+ekpump(n_r))*    uphi0(n_r) )

               if ( l_vphi_bal_calc ) then
                  vp_bal%visc(n_r)=d2uphi0(n_r)+or1(n_r)*duphi0(n_r)-&
                  &                or2(n_r)*uphi0(n_r)
                  vp_bal%pump(n_r)=-ekpump(n_r)*uphi0(n_r)
               end if
            else
               dm2 = real(m,cp)*real(m,cp)
               dpsidtLast_Mloc(n_m,n_r)=dpsidt_Mloc(n_m,n_r)        &
               &                -coex*    (     work_Mloc(n_m,n_r)  &
               &                   +or1(n_r)*    dom_Mloc(n_m,n_r)  &
               & -(ekpump(n_r)+dm2*or2(n_r))*     om_Mloc(n_m,n_r)  &
               & +half*ekpump(n_r)*beta(n_r)*     up_Mloc(n_m,n_r)  &
               & +( CorFac*beta(n_r) +                              &
               &  ekpump(n_r)*beta(n_r)*(-ci*real(m,cp)+            &
               &              5.0_cp*r_cmb*oheight(n_r)) )*         &
               &                                  us_Mloc(n_m,n_r)  &
               & -rgrav(n_r)*or1(n_r)*ra*opr*ci*real(m,cp)*         &
               &                                   t_Mloc(n_m,n_r))
            end if
         end do
      end do

   end subroutine get_rhs_om
!------------------------------------------------------------------------------
   subroutine get_psiMat(dt, m, psiMat, psiPivot, psiMat_fac)

      !-- Input variables
      real(cp), intent(in) :: dt        ! time step
      integer,  intent(in) :: m

      !-- Output variables
      complex(cp), intent(out) :: psiMat(2*n_r_max,2*n_r_max)
      integer,  intent(out) :: psiPivot(2*n_r_max)
      real(cp),intent(out) :: psiMat_fac(2*n_r_max,2)

      !-- Local variables
      integer :: nR_out, nR, nR_psi, nR_out_psi, info
      real(cp) :: O_dt,dm2

      O_dt=one/dt
      dm2 = real(m,cp)*real(m,cp)

      !----- Boundary conditions:
      do nR_out=1,rscheme%n_max

         nR_out_psi = nR_out+n_r_max

         !-- Non-penetation condition
         psiMat(1,nR_out)          =0.0_cp
         psiMat(1,nR_out_psi)      =rscheme%rnorm*rscheme%rMat(1,nR_out)
         psiMat(n_r_max,nR_out)    =0.0_cp
         psiMat(n_r_max,nR_out_psi)=rscheme%rnorm*rscheme%rMat(n_r_max,nR_out)

         if ( ktopv == 1 ) then ! free-slip
            psiMat(n_r_max+1,nR_out)    =0.0_cp
            psiMat(n_r_max+1,nR_out_psi)=rscheme%rnorm*(                &
            &                                 rscheme%d2rMat(1,nR_out)- &
            &                           or1(1)*rscheme%drMat(1,nR_out) )
         else
            psiMat(n_r_max+1,nR_out)    =0.0_cp
            psiMat(n_r_max+1,nR_out_psi)=rscheme%rnorm*rscheme%drMat(1,nR_out)
         end if
         if ( kbotv == 1 ) then
            psiMat(2*n_r_max,nR_out)    =0.0_cp
            psiMat(2*n_r_max,nR_out_psi)=rscheme%rnorm*(                 &
            &                            rscheme%d2rMat(n_r_max,nR_out)- &
            &                or1(n_r_max)*rscheme%drMat(n_r_max,nR_out) )
         else
            psiMat(2*n_r_max,nR_out)    =0.0_cp
            psiMat(2*n_r_max,nR_out_psi)=rscheme%rnorm* &
            &                            rscheme%drMat(n_r_max,nR_out)
         end if
      end do


      if ( rscheme%n_max < n_r_max ) then ! fill with zeros !
         do nR_out=rscheme%n_max+1,n_r_max
            nR_out_psi = nR_out+n_r_max
            psiMat(1,nR_out)            =0.0_cp
            psiMat(n_r_max,nR_out)      =0.0_cp
            psiMat(n_r_max+1,nR_out)    =0.0_cp
            psiMat(2*n_r_max,nR_out)    =0.0_cp
            psiMat(1,nR_out_psi)        =0.0_cp
            psiMat(n_r_max,nR_out_psi)  =0.0_cp
            psiMat(n_r_max+1,nR_out_psi)=0.0_cp
            psiMat(2*n_r_max,nR_out_psi)=0.0_cp
         end do
      end if

      !----- Other points:
      do nR_out=1,n_r_max
         nR_out_psi=nR_out+n_r_max
         do nR=2,n_r_max-1
            nR_psi=nR+n_r_max

            psiMat(nR,nR_out)= rscheme%rnorm * (                      &
            &                          O_dt*rscheme%rMat(nR,nR_out) - &
            &          alpha*(            rscheme%d2rMat(nR,nR_out) + &
            &          or1(nR)*            rscheme%drMat(nR,nR_out) - &
            &  (ekpump(nR)+dm2*or2(nR))*    rscheme%rMat(nR,nR_out) ) )

            psiMat(nR,nR_out_psi)=-rscheme%rnorm * alpha* (           &
            &    -half*ekpump(nR)*beta(nR)*rscheme%drMat(nR,nR_out)+  &
            &        ( CorFac*beta(nR)*or1(nR)*ci*real(m,cp)          &
            &    -half*ekpump(nR)*beta(nR)*beta(nR)                   &
            &   +ekpump(nR)*beta(nR)*or1(nR)*( dm2+                   &
            &              5.0_cp*r_cmb*oheight(nR)*ci*real(m,cp)) )* &
            &                               rscheme%rMat(nR,nR_out) ) 

            psiMat(nR_psi,nR_out)= rscheme%rnorm*rscheme%rMat(nR,nR_out)

            psiMat(nR_psi,nR_out_psi)= rscheme%rnorm * (              &
            &                             rscheme%d2rMat(nR,nR_out) + &
            &      (or1(nR)+beta(nR))*     rscheme%drMat(nR,nR_out) + &
            &  (or1(nR)*beta(nR)+dbeta(nR)-dm2*or2(nR))*              &
            &                               rscheme%rMat(nR,nR_out) )

         end do
      end do

      !----- Factor for highest and lowest cheb:
      do nR=1,n_r_max
         nR_psi = nR+n_r_max
         psiMat(nR,1)            =rscheme%boundary_fac*psiMat(nR,1)
         psiMat(nR,n_r_max)      =rscheme%boundary_fac*psiMat(nR,n_r_max)
         psiMat(nR,n_r_max+1)    =rscheme%boundary_fac*psiMat(nR,n_r_max+1)
         psiMat(nR,2*n_r_max)    =rscheme%boundary_fac*psiMat(nR,2*n_r_max)
         psiMat(nR_psi,1)        =rscheme%boundary_fac*psiMat(nR_psi,1)
         psiMat(nR_psi,n_r_max)  =rscheme%boundary_fac*psiMat(nR_psi,n_r_max)
         psiMat(nR_psi,n_r_max+1)=rscheme%boundary_fac*psiMat(nR_psi,n_r_max+1)
         psiMat(nR_psi,2*n_r_max)=rscheme%boundary_fac*psiMat(nR_psi,2*n_r_max)
      end do

      ! compute the linesum of each line
      do nR=1,2*n_r_max
         psiMat_fac(nR,1)=one/maxval(abs(psiMat(nR,:)))
      end do
      ! now divide each line by the linesum to regularize the matrix
      do nR=1,2*n_r_max
         psiMat(nR,:) = psiMat(nR,:)*psiMat_fac(nR,1)
      end do

      ! also compute the rowsum of each column
      do nR=1,2*n_r_max
         psiMat_fac(nR,2)=one/maxval(abs(psiMat(:,nR)))
      end do
      ! now divide each row by the rowsum
      do nR=1,2*n_r_max
         psiMat(:,nR) = psiMat(:,nR)*psiMat_fac(nR,2)
      end do

      !----- LU decomposition:
      call cgefa(psiMat,2*n_r_max,2*n_r_max,psiPivot,info)
      if ( info /= 0 ) then
         call abortRun('Singular matrix psiMat!')
      end if


   end subroutine get_psiMat
!------------------------------------------------------------------------------
   subroutine get_uphiMat(dt, uphiMat, uphiPivot)

      !-- Input variables
      real(cp), intent(in) :: dt        ! time step

      !-- Output variables
      real(cp), intent(out) :: uphiMat(n_r_max,n_r_max)
      integer,  intent(out) :: uphiPivot(n_r_max)

      !-- Local variables
      integer :: nR_out, nR, info
      real(cp) :: O_dt

      O_dt=one/dt

      !----- Boundary conditions:
      do nR_out=1,rscheme%n_max
         if ( ktopv == 1 ) then !-- Free-slip
            uphiMat(1,nR_out)=rscheme%rnorm*(rscheme%drMat(1,nR_out)-or1(1)* &
            &                                 rscheme%rMat(1,nR_out))
         else
            uphiMat(1,nR_out)=rscheme%rnorm*rscheme%rMat(1,nR_out)
         end if
         if ( kbotv == 1 ) then !-- Free-slip
            uphiMat(n_r_max,nR_out)=rscheme%rnorm*(                 &
            &                        rscheme%drMat(n_r_max,nR_out)  &
            &           -or1(n_r_max)*rscheme%rMat(n_r_max,nR_out))
         else
            uphiMat(n_r_max,nR_out)=rscheme%rnorm* &
            &                       rscheme%rMat(n_r_max,nR_out)
         end if
      end do


      if ( rscheme%n_max < n_r_max ) then ! fill with zeros !
         do nR_out=rscheme%n_max+1,n_r_max
            uphiMat(1,nR_out)      =0.0_cp
            uphiMat(n_r_max,nR_out)=0.0_cp
         end do
      end if


      !----- Other points:
      do nR_out=1,n_r_max
         do nR=2,n_r_max-1
            uphiMat(nR,nR_out)= rscheme%rnorm * (                     &
            &                          O_dt*rscheme%rMat(nR,nR_out) - &
            &     alpha*     (            rscheme%d2rMat(nR,nR_out) + &
            &          or1(nR)*            rscheme%drMat(nR,nR_out) - &
            &   (ekpump(nR)+or2(nR))*       rscheme%rMat(nR,nR_out) ) )
         end do
      end do

      !----- Factor for highest and lowest cheb:
      do nR=1,n_r_max
         uphiMat(nR,1)      =rscheme%boundary_fac*uphiMat(nR,1)
         uphiMat(nR,n_r_max)=rscheme%boundary_fac*uphiMat(nR,n_r_max)
      end do

      !----- LU decomposition:
      call sgefa(uphiMat,n_r_max,n_r_max,uphiPivot,info)
      if ( info /= 0 ) then
         call abortRun('Singular matrix uphiMat!')
      end if

   end subroutine get_uphiMat
!------------------------------------------------------------------------------
end module update_psi