module algebra

   use omp_lib
   use precision_mod
   use constants, only: one
   use useful, only: abortRun

   implicit none

   private

   real(cp), parameter :: zero_tolerance=1.0e-15_cp

   public :: prepare_mat, solve_mat, prepare_band, solve_band, &
   &         prepare_tridiag, solve_tridiag

   interface solve_mat
      module procedure solve_mat_real_rhs
      module procedure solve_mat_complex_rhs
      module procedure solve_mat_complex_rhs_multi
      module procedure solve_mat_real_rhs_multi
   end interface solve_mat

   interface solve_tridiag
      module procedure solve_tridiag_real_rhs
      module procedure solve_tridiag_complex_rhs
      module procedure solve_tridiag_complex_rhs_multi
      module procedure solve_tridiag_real_rhs_multi
   end interface solve_tridiag

   interface solve_band
      module procedure solve_band_real_rhs
      module procedure solve_band_complex_rhs_multi
      module procedure solve_band_real_rhs_multi
      module procedure solve_band_complex_rhs
   end interface solve_band

contains

   subroutine solve_mat_complex_rhs(a,ia,n,ip,bc1)
      !
      !  This routine does the backward substitution into a lu-decomposed real 
      !  matrix a (to solve a * x = bc1) were bc1 is the right hand side  
      !  vector. On return x is stored in bc1.                            
      !                                                                     

      !-- Input variables:
      integer,  intent(in) :: n         ! dimension of problem
      integer,  intent(in) :: ia        ! first dim of a
      integer,  intent(in) :: ip(*)     ! pivot pointer of legth n
      real(cp), intent(in) :: a(ia,*)    ! real n X n matrix

      !-- Output: solution stored in bc1(*)
      complex(cp), intent(inout) :: bc1(*) ! on input RHS of problem

      !-- Local variables:
      integer :: nm1,nodd,i,m
      integer :: k,k1
      complex(cp) :: c1

      nm1=n-1
      nodd=mod(n,2)

      !--   permute vectors b1
      do k=1,nm1
         m=ip(k)
         c1=bc1(m)
         bc1(m)=bc1(k)
         bc1(k)=c1
      end do

      !--   solve  l * y = b
      do k=1,n-2,2
         k1=k+1
         bc1(k1)=bc1(k1)-bc1(k)*a(k1,k)
         do i=k+2,n
            bc1(i)=bc1(i)-(bc1(k)*a(i,k)+bc1(k1)*a(i,k1))
         end do
      end do

      if ( nodd == 0 ) then
         bc1(n)=bc1(n)-bc1(nm1)*a(n,nm1)
      end if

      !--   solve  u * x = y
      do k=n,3,-2
         k1=k-1
         bc1(k)=bc1(k)*a(k,k)
         bc1(k1)=(bc1(k1)-bc1(k)*a(k1,k))*a(k1,k1)
         do i=1,k-2
            bc1(i)=bc1(i)-bc1(k)*a(i,k)-bc1(k1)*a(i,k1)
         end do
      end do

      if ( nodd == 0 ) then
         bc1(2)=bc1(2)*a(2,2)
         bc1(1)=(bc1(1)-bc1(2)*a(1,2))*a(1,1)
      else
         bc1(1)=bc1(1)*a(1,1)
      end if

   end subroutine solve_mat_complex_rhs
!-----------------------------------------------------------------------------
   subroutine solve_mat_complex_rhs_multi(a,ia,n,ip,bc,nRHSs)
      !
      !  This routine does the backward substitution into a lu-decomposed real
      !  matrix a (to solve a * x = bc ) simultaneously for nRHSs complex
      !  vectors bc. On return the results are stored in the bc.
      !

      !-- Input variables:
      integer,  intent(in) :: n           ! dimension of problem
      integer,  intent(in) :: ia          ! leading dimension of a
      integer,  intent(in) :: ip(n)       ! pivot pointer of length n
      real(cp), intent(in) :: a(ia,n)     ! real n X n matrix
      integer,  intent(in) :: nRHSs       ! number of right-hand sides

      complex(cp), intent(inout) :: bc(:,:) ! on input RHS of problem

      !-- Local variables:
      integer :: nm1,nodd,i,m
      integer :: k,k1,nRHS,nRHS2,noddRHS
      complex(cp) :: help

      nm1    = n-1
      nodd   = mod(n,2)
      noddRHS= mod(nRHSs,2)

      !     permute vectors bc
      do nRHS=1,nRHSs
         do k=1,nm1
            m=ip(k)
            help       =bc(m,nRHS)
            bc(m,nRHS) =bc(k,nRHS)
            bc(k,nRHS) =help
         end do
      end do

      !     solve  l * y = b

      !write(*,"(A,I4,A,I2,A)") "OpenMP loop over ",(nRHSs-1)/2,&
      !     &" iterations on ",omp_get_num_threads()," threads"
      do nRHS=1,nRHSs-1,2
         nRHS2=nRHS+1

         do k=1,n-2,2
            k1=k+1
            bc(k1,nRHS) =bc(k1,nRHS)-bc(k,nRHS)*a(k1,k)
            bc(k1,nRHS2)=bc(k1,nRHS2)-bc(k,nRHS2)*a(k1,k)
            do i=k+2,n
               bc(i,nRHS) =bc(i,nRHS) - (bc(k,nRHS)*a(i,k)+bc(k1,nRHS)*a(i,k1))
               bc(i,nRHS2)=bc(i,nRHS2) - (bc(k,nRHS2)*a(i,k)+bc(k1,nRHS2)*a(i,k1))
            end do
         end do
         if ( nodd == 0 ) then
            bc(n,nRHS) =bc(n,nRHS) -bc(nm1,nRHS)*a(n,nm1)
            bc(n,nRHS2)=bc(n,nRHS2)-bc(nm1,nRHS2)*a(n,nm1)
         end if

         !     solve  u * x = y
         do k=n,3,-2
            k1=k-1
            bc(k,nRHS)  =bc(k,nRHS)*a(k,k)
            bc(k1,nRHS) =(bc(k1,nRHS)-bc(k,nRHS)*a(k1,k))*a(k1,k1)
            bc(k,nRHS2) =bc(k,nRHS2)*a(k,k)
            bc(k1,nRHS2)=(bc(k1,nRHS2)-bc(k,nRHS2)*a(k1,k))*a(k1,k1)
            do i=1,k-2
               bc(i,nRHS)=bc(i,nRHS) - bc(k,nRHS)*a(i,k)-bc(k1,nRHS)*a(i,k1)
               bc(i,nRHS2)=bc(i,nRHS2) - bc(k,nRHS2)*a(i,k)-bc(k1,nRHS2)*a(i,k1)
            end do
         end do
         if ( nodd == 0 ) then
            bc(2,nRHS)=bc(2,nRHS)*a(2,2)
            bc(1,nRHS)=(bc(1,nRHS)-bc(2,nRHS)*a(1,2))*a(1,1)
            bc(2,nRHS2)=bc(2,nRHS2)*a(2,2)
            bc(1,nRHS2)=(bc(1,nRHS2)-bc(2,nRHS2)*a(1,2))*a(1,1)
         else
            bc(1,nRHS)=bc(1,nRHS)*a(1,1)
            bc(1,nRHS2)=bc(1,nRHS2)*a(1,1)
         end if

      end do

      if ( noddRHS == 1 ) then
         nRHS=nRHSs

         do k=1,n-2,2
            k1=k+1
            bc(k1,nRHS)=bc(k1,nRHS)-bc(k,nRHS)*a(k1,k)
            do i=k+2,n
               bc(i,nRHS)=bc(i,nRHS) - (bc(k,nRHS)*a(i,k)+bc(k1,nRHS)*a(i,k1))
            end do
         end do
         if ( nodd == 0 ) bc(n,nRHS)=bc(n,nRHS)-bc(nm1,nRHS)*a(n,nm1)
         do k=n,3,-2
            k1=k-1
            bc(k,nRHS) =bc(k,nRHS)*a(k,k)
            bc(k1,nRHS)=(bc(k1,nRHS)-bc(k,nRHS)*a(k1,k))*a(k1,k1)
            do i=1,k-2
               bc(i,nRHS)=bc(i,nRHS) - bc(k,nRHS)*a(i,k)-bc(k1,nRHS)*a(i,k1)
            end do
         end do
         if ( nodd == 0 ) then
            bc(2,nRHS)=bc(2,nRHS)*a(2,2)
            bc(1,nRHS)=(bc(1,nRHS)-bc(2,nRHS)*a(1,2))*a(1,1)
         else
            bc(1,nRHS)=bc(1,nRHS)*a(1,1)
         end if

      end if

   end subroutine solve_mat_complex_rhs_multi
!-----------------------------------------------------------------------------
   subroutine solve_mat_real_rhs_multi(a,ia,n,ip,bc,nRHSs)
      !
      !  This routine does the backward substitution into a lu-decomposed real
      !  matrix a (to solve a * x = bc ) simultaneously for nRHSs real
      !  vectors bc. On return the results are stored in the bc.
      !

      !-- Input variables:
      integer,  intent(in) :: n           ! dimension of problem
      integer,  intent(in) :: ia          ! leading dimension of a
      integer,  intent(in) :: ip(n)       ! pivot pointer of length n
      real(cp), intent(in) :: a(ia,n)     ! real n X n matrix
      integer,  intent(in) :: nRHSs       ! number of right-hand sides

      real(cp), intent(inout) :: bc(:,:) ! on input RHS of problem

      !-- Local variables:
      integer :: nm1,nodd,i,m
      integer :: k,k1,nRHS,nRHS2,noddRHS
      real(cp) :: help

      nm1    = n-1
      nodd   = mod(n,2)
      noddRHS= mod(nRHSs,2)

      !     permute vectors bc
      do nRHS=1,nRHSs
         do k=1,nm1
            m=ip(k)
            help       =bc(m,nRHS)
            bc(m,nRHS) =bc(k,nRHS)
            bc(k,nRHS) =help
         end do
      end do

      !     solve  l * y = b
      do nRHS=1,nRHSs-1,2
         nRHS2=nRHS+1

         do k=1,n-2,2
            k1=k+1
            bc(k1,nRHS) =bc(k1,nRHS)-bc(k,nRHS)*a(k1,k)
            bc(k1,nRHS2)=bc(k1,nRHS2)-bc(k,nRHS2)*a(k1,k)
            do i=k+2,n
               bc(i,nRHS) =bc(i,nRHS) - (bc(k,nRHS)*a(i,k)+bc(k1,nRHS)*a(i,k1))
               bc(i,nRHS2)=bc(i,nRHS2) - (bc(k,nRHS2)*a(i,k)+bc(k1,nRHS2)*a(i,k1))
            end do
         end do
         if ( nodd == 0 ) then
            bc(n,nRHS) =bc(n,nRHS) -bc(nm1,nRHS)*a(n,nm1)
            bc(n,nRHS2)=bc(n,nRHS2)-bc(nm1,nRHS2)*a(n,nm1)
         end if

         !     solve  u * x = y
         do k=n,3,-2
            k1=k-1
            bc(k,nRHS)  =bc(k,nRHS)*a(k,k)
            bc(k1,nRHS) =(bc(k1,nRHS)-bc(k,nRHS)*a(k1,k))*a(k1,k1)
            bc(k,nRHS2) =bc(k,nRHS2)*a(k,k)
            bc(k1,nRHS2)=(bc(k1,nRHS2)-bc(k,nRHS2)*a(k1,k))*a(k1,k1)
            do i=1,k-2
               bc(i,nRHS)=bc(i,nRHS) - bc(k,nRHS)*a(i,k)-bc(k1,nRHS)*a(i,k1)
               bc(i,nRHS2)=bc(i,nRHS2) - bc(k,nRHS2)*a(i,k)-bc(k1,nRHS2)*a(i,k1)
            end do
         end do
         if ( nodd == 0 ) then
            bc(2,nRHS)=bc(2,nRHS)*a(2,2)
            bc(1,nRHS)=(bc(1,nRHS)-bc(2,nRHS)*a(1,2))*a(1,1)
            bc(2,nRHS2)=bc(2,nRHS2)*a(2,2)
            bc(1,nRHS2)=(bc(1,nRHS2)-bc(2,nRHS2)*a(1,2))*a(1,1)
         else
            bc(1,nRHS)=bc(1,nRHS)*a(1,1)
            bc(1,nRHS2)=bc(1,nRHS2)*a(1,1)
         end if

      end do

      if ( noddRHS == 1 ) then
         nRHS=nRHSs

         do k=1,n-2,2
            k1=k+1
            bc(k1,nRHS)=bc(k1,nRHS)-bc(k,nRHS)*a(k1,k)
            do i=k+2,n
               bc(i,nRHS)=bc(i,nRHS) - (bc(k,nRHS)*a(i,k)+bc(k1,nRHS)*a(i,k1))
            end do
         end do
         if ( nodd == 0 ) bc(n,nRHS)=bc(n,nRHS)-bc(nm1,nRHS)*a(n,nm1)
         do k=n,3,-2
            k1=k-1
            bc(k,nRHS) =bc(k,nRHS)*a(k,k)
            bc(k1,nRHS)=(bc(k1,nRHS)-bc(k,nRHS)*a(k1,k))*a(k1,k1)
            do i=1,k-2
               bc(i,nRHS)=bc(i,nRHS) - bc(k,nRHS)*a(i,k)-bc(k1,nRHS)*a(i,k1)
            end do
         end do
         if ( nodd == 0 ) then
            bc(2,nRHS)=bc(2,nRHS)*a(2,2)
            bc(1,nRHS)=(bc(1,nRHS)-bc(2,nRHS)*a(1,2))*a(1,1)
         else
            bc(1,nRHS)=bc(1,nRHS)*a(1,1)
         end if

      end if

   end subroutine solve_mat_real_rhs_multi
!-----------------------------------------------------------------------------
   subroutine solve_mat_real_rhs(a,ia,n,ip,b)
      !
      !     like the linpack routine
      !     backward substitution of vector b into lu-decomposed matrix a
      !     to solve  a * x = b for a single real vector b
      !
      !     sub sgefa must be called once first to initialize a and ip
      !
      !     a: (input)  nxn real matrix
      !     n: (input)  size of a and b
      !     ip: (input) pivot pointer array of length n
      !     b: (in/output) rhs-vector on input, solution on output
      !

      !-- Input variables:
      integer,  intent(in) :: n      ! dim of problem
      integer,  intent(in) :: ia     ! first dim of a
      integer,  intent(in) :: ip(*)  ! pivot information
      real(cp), intent(in) :: a(ia,*)

      !-- Output: solution stored in b(n)
      real(cp), intent(inout) :: b(*)

      !-- Local variables:
      integer :: nm1,i
      integer :: k,k1,m,nodd
      real(cp) :: help


      nm1 =n-1
      nodd=mod(n,2)

      !--   permute vector b
      do k=1,nm1
         m   =ip(k)
         help=b(m)
         b(m)=b(k)
         b(k)=help
      end do

      !--   solve  l * y = b
      do k=1,n-2,2
         k1=k+1
         b(k1)=b(k1)-b(k)*a(k1,k)
         do i=k+2,n
            b(i)=b(i)-(b(k)*a(i,k)+b(k1)*a(i,k1))
         end do
      end do
      if ( nodd == 0 ) b(n)=b(n)-b(nm1)*a(n,nm1)

      !--   solve  u * x = y
      do k=n,3,-2
         k1=k-1
         b(k) =b(k)*a(k,k)
         b(k1)=(b(k1)-b(k)*a(k1,k))*a(k1,k1)
         do i=1,k-2
            b(i)=b(i)-(b(k)*a(i,k)+b(k1)*a(i,k1))
         end do
      end do
      if ( nodd == 0 ) then
         b(2)=b(2)*a(2,2)
         b(1)=(b(1)-b(2)*a(1,2))*a(1,1)
      else
         b(1)=b(1)*a(1,1)
      end if

   end subroutine solve_mat_real_rhs
!-----------------------------------------------------------------------------
   subroutine prepare_mat(a,ia,n,ip,info)
      !
      !     like the linpack routine
      !
      !     lu decomposes the real matrix a(n,n) via gaussian elimination
      !
      !     a: (in/output) real nxn matrix on input, lu-decomposed matrix on output
      !     ia: (input) first dimension of a (must be >= n)
      !     n: (input) 2nd dimension and rank of a
      !     ip: (output) pivot pointer array
      !     info: (output) error message when  /=  0
      !

      !-- Input variables:
      integer,  intent(in) :: ia,n
      real(cp), intent(inout) :: a(ia,*)

      !-- Output variables:
      integer, intent(out) :: ip(*)   ! pivoting information
      integer, intent(out) :: info

      !-- Local variables:
      integer :: nm1,k,kp1,l,i,j
      real(cp) :: help

      if ( n <= 1 ) call abortRun('Stop run in sgefa')

      info=0
      nm1 =n-1

      do k=1,nm1
         kp1=k+1
         l  =k

         do i=kp1,n
            if ( abs(a(i,k)) > abs(a(l,k)) ) l=i
         end do

         ip(k)=l

         if ( abs(a(l,k))  >  zero_tolerance ) then

            if ( l /= k ) then
               do i=1,n
                  help  =a(k,i)
                  a(k,i)=a(l,i)
                  a(l,i)=help
               end do
            end if

            help=one/a(k,k)
            do i=kp1,n
               a(i,k)=help*a(i,k)
            end do

            do j=kp1,n
               do i=kp1,n
                  a(i,j)=a(i,j)-a(k,j)*a(i,k)
               end do
            end do

         else
            info=k
         end if

      end do

      ip(n)=n
      if ( abs(a(n,n))  <=  zero_tolerance ) info=n
      if ( info > 0 ) return

      do i=1,n
         a(i,i)=one/a(i,i)
      end do

   end subroutine prepare_mat
!-----------------------------------------------------------------------------
   subroutine solve_band_real_rhs(abd, n, kl, ku, pivot, rhs)

      !-- Input variables
      integer,  intent(in) :: kl
      integer,  intent(in) :: ku
      integer,  intent(in) :: n
      integer,  intent(in) :: pivot(n)
      real(cp), intent(in) :: abd(2*kl+ku+1, n)

      !-- Output variable
      real(cp), intent(out) :: rhs(n)

      !-- Local variables
      real(cp) :: t
      integer :: k, kb, l, la, lb, lm, m, nm1

      m = ku + kl + 1
      nm1 = n - 1

      !-- First solve Ly = rhs
      if ( kl /= 0 .and. nm1 >= 1) then
         do k = 1, nm1
            lm = min(kl,n-k)
            l = pivot(k)
            t = rhs(l)
            if (l /= k) then
               rhs(l) = rhs(k)
               rhs(k) = t
            end if
            rhs(k+1:k+lm)=rhs(k+1:k+lm)+t*abd(m+1:m+lm,k)
         end do
      end if

      !-- Solve u*x =y
      do kb = 1, n
         k = n + 1 - kb
         rhs(k) = rhs(k)/abd(m,k)
         lm = min(k,m) - 1
         la = m - lm
         lb = k - lm
         t = -rhs(k)
         rhs(lb:lb+lm-1)=rhs(lb:lb+lm-1)+t*abd(la:la+lm-1,k)
      end do

   end subroutine solve_band_real_rhs
!-----------------------------------------------------------------------------
   subroutine solve_band_complex_rhs(abd, n, kl, ku, pivot, rhs)

      !-- Input variables
      integer,  intent(in) :: kl
      integer,  intent(in) :: ku
      integer,  intent(in) :: n
      integer,  intent(in) :: pivot(n)
      real(cp), intent(in) :: abd(2*kl+ku+1, n)

      !-- Output variable
      complex(cp), intent(out) :: rhs(n)

      !-- Local variables
      complex(cp) :: t
      integer :: k, kb, l, la, lb, lm, m, nm1

      m = ku + kl + 1
      nm1 = n - 1

      !-- First solve Ly = rhs
      if ( kl /= 0 .and. nm1 >= 1) then
         do k = 1, nm1
            lm = min(kl,n-k)
            l = pivot(k)
            t = rhs(l)
            if (l /= k) then
               rhs(l) = rhs(k)
               rhs(k) = t
            end if
            rhs(k+1:k+lm)=rhs(k+1:k+lm)+t*abd(m+1:m+lm,k)
         end do
      end if

      !-- Solve u*x =y
      do kb = 1, n
         k = n + 1 - kb
         rhs(k) = rhs(k)/abd(m,k)
         lm = min(k,m) - 1
         la = m - lm
         lb = k - lm
         t = -rhs(k)
         rhs(lb:lb+lm-1)=rhs(lb:lb+lm-1)+t*abd(la:la+lm-1,k)
      end do

   end subroutine solve_band_complex_rhs
!-----------------------------------------------------------------------------
   subroutine solve_band_complex_rhs_multi(abd, n, kl, ku, pivot, rhs, nRHSs)

      !-- Input variables
      integer,  intent(in) :: kl
      integer,  intent(in) :: ku
      integer,  intent(in) :: n
      integer,  intent(in) :: nRHSs
      integer,  intent(in) :: pivot(n)
      real(cp), intent(in) :: abd(2*kl+ku+1, n)

      !-- Output variable
      complex(cp), intent(inout) :: rhs(:,:)

      !-- Local variables
      complex(cp) :: t
      integer :: k, kb, l, la, lb, lm, m, nm1, nRHS

      m = ku + kl + 1
      nm1 = n - 1

      !-- First solve Ly = rhs
      if ( kl /= 0 .and. nm1 >= 1) then
         do nRHS=1,nRHSs
            do k = 1, nm1
               lm = min(kl,n-k)
               l = pivot(k)
               t = rhs(l,nRHS)
               if (l /= k) then
                  rhs(l,nRHS) = rhs(k,nRHS)
                  rhs(k,nRHS) = t
               end if
               rhs(k+1:k+lm,nRHS)=rhs(k+1:k+lm,nRHS)+t*abd(m+1:m+lm,k)
            end do
         end do
      end if

      !-- Solve u*x =y
      do nRHS=1,nRHSs
         do kb = 1, n
            k = n + 1 - kb
            rhs(k,nRHS) = rhs(k,nRHS)/abd(m,k)
            lm = min(k,m) - 1
            la = m - lm
            lb = k - lm
            t = -rhs(k,nRHS)
            rhs(lb:lb+lm-1,nRHS)=rhs(lb:lb+lm-1,nRHS)+t*abd(la:la+lm-1,k)
         end do
      end do

   end subroutine solve_band_complex_rhs_multi
!-----------------------------------------------------------------------------
   subroutine solve_band_real_rhs_multi(abd, n, kl, ku, pivot, rhs, nRHSs)

      !-- Input variables
      integer,  intent(in) :: kl
      integer,  intent(in) :: ku
      integer,  intent(in) :: n
      integer,  intent(in) :: nRHSs
      integer,  intent(in) :: pivot(n)
      real(cp), intent(in) :: abd(2*kl+ku+1, n)

      !-- Output variable
      real(cp), intent(inout) :: rhs(:,:)

      !-- Local variables
      real(cp) :: t
      integer :: k, kb, l, la, lb, lm, m, nm1, nRHS

      m = ku + kl + 1
      nm1 = n - 1

      !-- First solve Ly = rhs
      if ( kl /= 0 .and. nm1 >= 1) then
         do nRHS=1,nRHSs
            do k = 1, nm1
               lm = min(kl,n-k)
               l = pivot(k)
               t = rhs(l,nRHS)
               if (l /= k) then
                  rhs(l,nRHS) = rhs(k,nRHS)
                  rhs(k,nRHS) = t
               end if
               rhs(k+1:k+lm,nRHS)=rhs(k+1:k+lm,nRHS)+t*abd(m+1:m+lm,k)
            end do
         end do
      end if

      !-- Solve u*x =y
      do nRHS=1,nRHSs
         do kb = 1, n
            k = n + 1 - kb
            rhs(k,nRHS) = rhs(k,nRHS)/abd(m,k)
            lm = min(k,m) - 1
            la = m - lm
            lb = k - lm
            t = -rhs(k,nRHS)
            rhs(lb:lb+lm-1,nRHS)=rhs(lb:lb+lm-1,nRHS)+t*abd(la:la+lm-1,k)
         end do
      end do

   end subroutine solve_band_real_rhs_multi
!-----------------------------------------------------------------------------
   subroutine prepare_band(abd,n,kl,ku,pivot,info)

      !-- Input variables
      integer, intent(in) :: n
      integer, intent(in) :: kl, ku
      real(cp), intent(inout) :: abd(2*kl+ku+1,n)

      !-- Output variables
      integer, intent(out) :: pivot(n)
      integer, intent(out) :: info

      !-- Local variables
      real(cp) ::  t
      integer :: i, i0, j, ju, jz, j0, j1, k, kp1, l, lm, m, mm, nm1

      m = kl + ku + 1
      info = 0

      j0 = ku + 2
      j1 = min(n,m) - 1
      if ( j1 >= j0 ) then
         do jz = j0, j1
            i0 = m + 1 - jz
            do i = i0, kl
               abd(i,jz) = 0.0_cp
            end do
         end do
      end if
      jz = j1
      ju = 0

      !-- Gaussian elimination
      nm1 = n - 1
      if (nm1 >= 1) then
         do k = 1, nm1
            kp1 = k + 1

            jz = jz + 1
            if ( jz <= n .and. kl >= 1 ) then
               do i = 1, kl
                  abd(i,jz) = 0.0_cp
               end do
            end if

            lm = min(kl,n-k)
            !l = isamax(lm+1,abd(m,k)) + m - 1
            l = maxloc(abs(abd(m:m+lm,k)),dim=1)+m-1

            pivot(k) = l + k - m

            if ( abs(abd(l,k)) > zero_tolerance ) then

               if (l /= m) then
                  t = abd(l,k)
                  abd(l,k) = abd(m,k)
                  abd(m,k) = t
               end if

               !-- Compute multipliers
               t = -1.0_cp/abd(m,k)
               abd(m+1:,k)=t*abd(m+1:,k)

               !-- Row elimination
               ju = min(max(ju,ku+pivot(k)),n)
               mm = m
               if ( ju >=  kp1 ) then
                  do j = kp1, ju
                     l = l - 1
                     mm = mm - 1
                     t = abd(l,j)
                     if ( l /= mm) then
                        abd(l,j) = abd(mm,j)
                        abd(mm,j) = t
                     end if
                     abd(mm+1:mm+lm,j)=abd(mm+1:mm+lm,j)+t*abd(m+1:m+lm,k)
                  end do
               end if
            else
               info = k
            end if
         end do
      end if

      pivot(n) = n

      if ( abs(abd(m,n)) <= zero_tolerance ) info = n

   end subroutine prepare_band
!-----------------------------------------------------------------------------
   subroutine solve_tridiag_real_rhs(dl,d,du,du2,n,pivot,rhs)

      !-- Input variables:
      integer,  intent(in) :: n         ! dim of problem
      integer,  intent(in) :: pivot(:)  ! pivot information
      real(cp), intent(in) :: d(:)      ! Diagonal
      real(cp), intent(in) :: dl(:)     ! Lower
      real(cp), intent(in) :: du(:)     ! Upper
      real(cp), intent(in) :: du2(:)    ! For pivot

      !-- Output: solution stored in rhs(n)
      real(cp), intent(inout) :: rhs(:)

      !-- Local variables
      integer :: i, ip
      real(cp) :: temp

      !-- Solve L*x = rhs.
      do i = 1, n-1
         ip = pivot(i)
         temp = rhs(i+1-ip+i)-dl(i)*rhs(ip)
         rhs(i) = rhs(ip)
         rhs(i+1) = temp
      end do

      !-- Solve U*x = rhs.
      rhs(n) = rhs(n)/d(n)
      rhs(n-1) = (rhs(N-1)-du(n-1)*rhs(n)) / d(n-1)
      do  i = n-2,1,-1
         rhs(i) = (rhs(i)-du(i)*rhs(i+1)-du2(i)*rhs(i+2)) / d(i)
      end do

   end subroutine solve_tridiag_real_rhs
!-----------------------------------------------------------------------------
   subroutine solve_tridiag_complex_rhs(dl,d,du,du2,n,pivot,rhs)

      !-- Input variables:
      integer,  intent(in) :: n         ! dim of problem
      integer,  intent(in) :: pivot(:)  ! pivot information
      real(cp), intent(in) :: d(:)      ! Diagonal
      real(cp), intent(in) :: dl(:)     ! Lower 
      real(cp), intent(in) :: du(:)     ! Lower 
      real(cp), intent(in) :: du2(:)    ! Upper

      !-- Output: solution stored in rhs(n)
      complex(cp), intent(inout) :: rhs(:)

      !-- Local variables
      integer :: i, ip
      complex(cp) :: temp

      !-- Solve L*x = rhs.
      do i = 1, n-1
         ip = pivot(i)
         temp = rhs(i+1-ip+i)-dl(i)*rhs(ip)
         rhs(i) = rhs(ip)
         rhs(i+1) = temp
      end do

      !-- Solve U*x = rhs.
      rhs(n) = rhs(n)/d(n)
      rhs(n-1) = (rhs(N-1)-du(n-1)*rhs(n)) / d(n-1)
      do  i = n-2,1,-1
         rhs(i) = (rhs(i)-du(i)*rhs(i+1)-du2(i)*rhs(i+2)) / d(i)
      end do

   end subroutine solve_tridiag_complex_rhs
!-----------------------------------------------------------------------------
   subroutine solve_tridiag_complex_rhs_multi(dl,d,du,du2,n,pivot,rhs,nRHSs)

      !-- Input variables:
      integer,  intent(in) :: n         ! dim of problem
      integer,  intent(in) :: pivot(:)  ! pivot information
      real(cp), intent(in) :: d(:)      ! Diagonal
      real(cp), intent(in) :: dl(:)     ! Lower
      real(cp), intent(in) :: du(:)     ! Upper
      real(cp), intent(in) :: du2(:)    ! For pivot
      integer,  intent(in) :: nRHSs     ! Number of right-hand side

      !-- Output: solution stored in rhs(n)
      complex(cp), intent(inout) :: rhs(:,:)

      !-- Local variables
      integer :: i, nRHS
      complex(cp) :: temp

      do nRHS = 1, nRHSs
         !-- Solve L*x = rhs.
         do i = 1, n-1
            if ( pivot(i) == i ) then
               rhs(i+1,nRHS) = rhs(i+1,nRHS) - dl(i)*rhs(i,nRHS)
            else
               temp = rhs(i,nRHS)
               rhs(i,nRHS) = rhs(i+1,nRHS)
               rhs(i+1,nRHS) = temp - dl(i)*RHS(i,nRHS)
            end if
         end do

         !-- Solve U*x = rhs.
         rhs(n,nRHS) = rhs(n,nRHS)/d(n)
         rhs(n-1,nRHS) = (rhs(n-1,nRHS)-du(n-1)*rhs(n,nRHS))/d(n-1)
         do i = n-2,1,-1
            rhs(i,nRHS) = (rhs(i,nRHS)-du(i)*rhs(i+1,nRHS)-du2(i)* &
            &              rhs(i+2,nRHS))/d(i)
         end do
      end do

   end subroutine solve_tridiag_complex_rhs_multi
!-----------------------------------------------------------------------------
   subroutine solve_tridiag_real_rhs_multi(dl,d,du,du2,n,pivot,rhs,nRHSs)

      !-- Input variables:
      integer,  intent(in) :: n         ! dim of problem
      integer,  intent(in) :: pivot(:)  ! pivot information
      real(cp), intent(in) :: d(:)      ! Diagonal
      real(cp), intent(in) :: dl(:)     ! Lower
      real(cp), intent(in) :: du(:)     ! Upper
      real(cp), intent(in) :: du2(:)    ! For pivot
      integer,  intent(in) :: nRHSs     ! Number of right-hand side

      !-- Output: solution stored in rhs(n)
      real(cp), intent(inout) :: rhs(:,:)

      !-- Local variables
      integer :: i, nRHS
      real(cp) :: temp

      do nRHS = 1, nRHSs
         !-- Solve L*x = rhs.
         do i = 1, n-1
            if ( pivot(i) == i ) then
               rhs(i+1,nRHS) = rhs(i+1,nRHS) - dl(i)*rhs(i,nRHS)
            else
               temp = rhs(i,nRHS)
               rhs(i,nRHS) = rhs(i+1,nRHS)
               rhs(i+1,nRHS) = temp - dl(i)*RHS(i,nRHS)
            end if
         end do

         !-- Solve U*x = rhs.
         rhs(n,nRHS) = rhs(n,nRHS)/d(n)
         rhs(n-1,nRHS) = (rhs(n-1,nRHS)-du(n-1)*rhs(n,nRHS))/d(n-1)
         do i = n-2,1,-1
            rhs(i,nRHS) = (rhs(i,nRHS)-du(i)*rhs(i+1,nRHS)-du2(i)* &
            &              rhs(i+2,nRHS))/d(i)
         end do
      end do

   end subroutine solve_tridiag_real_rhs_multi
!-----------------------------------------------------------------------------
   subroutine prepare_tridiag(dl,d,du,du2,n,pivot,info)

      !-- Input variable
      integer, intent(in) :: n

      !-- In/out variables:
      real(cp), intent(inout) :: d(:)
      real(cp), intent(inout) :: dl(:)
      real(cp), intent(inout) :: du(:)

      !-- Output variables
      integer,  intent(out) :: info
      integer,  intent(out) :: pivot(:)
      real(cp), intent(out) :: du2(:)

      !-- Local variables
      integer :: i
      real(cp) :: fact, temp

      info = 0
      !-- Initialize pivot(i) = i and du2(I) = 0
      do i = 1, n
         pivot(i) = i
      end do

      du2(:) = 0.0_cp
      do i = 1, n-2
         if ( abs(d(i)) >= abs(dl(i))) then
            !-- No row interchange required, eliminate DL(I)
            if ( d(i) > zero_tolerance ) then
               fact = dl(i)/d(i)
               dl(i) = fact
               d(i+1) = d(i+1) - fact*du(i)
            end if
         else
            !-- Interchange rows I and I+1, eliminate DL(I)
            fact = d(i)/dl(i)
            d(i) = dl(i)
            dl(i) = fact
            temp = du(i)
            du(i) = d(i+1)
            d(i+1) = temp - fact*d(i+1)
            du2(i) = du(i+1)
            du(i+1) = -fact*du(i+1)
            pivot(i) = i + 1
         end if
      end do

      i = n - 1
      if ( abs(d(i)) >= abs(dl(i)) ) then
         if ( d(i) > zero_tolerance ) then
            fact = dl(i)/d(i)
            dl(i) = fact
            d(i+1) = d(i+1) - fact*du(i)
         end if
      else
         fact = d(i) / dl(i)
         d(i) = dl(i)
         dl(i) = fact
         temp = du(i)
         du(i) = d(i+1)
         d(i+1) = temp - fact*d(i+1)
         pivot(i) = i + 1
      end if

      !-- Check for a zero on the diagonal of u.
      outer: do i = 1, n
         if ( d(i) <= zero_tolerance ) then
            info = i
            exit outer
         end if
      end do outer

   end subroutine prepare_tridiag
!-----------------------------------------------------------------------------
end module algebra
