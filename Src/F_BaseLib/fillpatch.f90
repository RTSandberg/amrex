module fillpatch_module

  use layout_module
  use fab_module
  use bl_mem_stat_module
  use multifab_module
  use bc_module
  use setbc_module
  use define_bc_module
  use multifab_physbc_module
  use interp_module

  implicit none

contains

  subroutine fillpatch(fine, crse, fine_domain, ng, ir, bc_crse, bc_fine, icomp, bcomp, nc)

    type(multifab), intent(inout) :: fine
    type(multifab), intent(inout) :: crse
    type(box     ), intent(in   ) :: fine_domain  ! TODO - this is not used.  Remove from call sequence.
    integer       , intent(in   ) :: ng
    integer       , intent(in   ) :: ir(:)
    type(bc_level), intent(in   ) :: bc_crse, bc_fine
    integer       , intent(in   ) :: icomp,bcomp,nc

    integer          :: i, j, dm, local_bc(crse%dim,2,nc)
    integer         :: lo(4), lo_f(3), lo_c(3), hi_f(3), hi_c(3), cslope_lo(2), cslope_hi(2)
    type(layout)    :: la, tmpla
    type(multifab)  :: cfine, tmpcrse
    type(box)       :: bx, fbx, cbx, fine_box, periodic_domain_box, crse_domain
    type(list_box)  :: bl
    type(boxarray)  :: ba, tmpba
    real(kind=dp_t) :: dx(3)
    logical         :: lim_slope, lin_limit
    logical         :: pmask(fine%dim)
    integer         :: grow_vect(fine%dim)

    real(kind=dp_t), allocatable :: fvcx(:), fvcy(:), fvcz(:)
    real(kind=dp_t), allocatable :: cvcx(:), cvcy(:), cvcz(:)

    real(kind=dp_t), pointer :: src(:,:,:,:), dst(:,:,:,:), fp(:,:,:,:)

    if ( nghost(fine) <  ng          ) call bl_error('fillpatch: fine does NOT have enough ghost cells')
    if ( nghost(crse) <  ng          ) call bl_error('fillpatch: crse does NOT have enough ghost cells')

    if ( .not. cell_centered_q(fine) ) call bl_error('fillpatch: fine is NOT cell centered')
    if ( .not. cell_centered_q(crse) ) call bl_error('fillpatch: crse is NOT cell centered')

    crse_domain = box_coarsen_v(fine_domain,ir)

    dx        = ONE
    dm        = crse%dim
    lim_slope = .true.
    lin_limit = .false.
    !
    ! Force crse to have good data in ghost cells (only the ng that are needed in case has more than ng).
    !
    call fill_boundary(crse, icomp, nc, ng)

    call multifab_physbc(crse,icomp,bcomp,nc,dx,bc_crse)

    !
    ! Build coarsened version of fine such that the fabs @ i are owned by the same CPUs.
    !
    periodic_domain_box = fine_domain
    pmask(1:dm) = layout_get_pmask(fine%la)
    grow_vect(:) = 0
    do i = 1, dm
       if (pmask(i)) grow_vect(i) = ng
    end do
    periodic_domain_box = grow(periodic_domain_box,grow_vect)

    do i = 1, nboxes(fine)
       !
       ! We don't use get_pbox here as we only want to fill ng ghost cells of fine & it may have more ghost cells than that.
       !
       bx =  grow(get_ibox(fine,i),ng)
       bx =  box_intersection(bx,periodic_domain_box)
       call push_back(bl,bx)
    end do

    call build(ba, bl, sort = .false.)

    call destroy(bl)

    call boxarray_coarsen(ba, ir)

    call boxarray_grow(ba, 1)      ! Grow by one for stencil in lin_cc_interp

    call build(la, ba, explicit_mapping = get_proc(fine%la))

    call destroy(ba)

    call build(cfine, la, nc = nc, ng = 0)
    !
    ! Fill cfine from crse.  Got to do it in stages as parallel copy only goes from valid -> valid.
    !
    do i = 1, nboxes(crse)
       bx = get_pbox(crse,i)
       call push_back(bl, bx)
    end do

    call build(tmpba, bl, sort = .false.)

    call destroy(bl)

    call build(tmpla, tmpba, explicit_mapping = get_proc(crse%la))

    call destroy(tmpba)

    call build(tmpcrse, tmpla, nc = nc, ng = 0)

    do i = 1, nboxes(crse)
       if ( remote(crse, i) ) cycle
       src => dataptr(crse,    i, 1,     nc)
       dst => dataptr(tmpcrse, i, icomp, nc)
       dst = src
    end do

    call copy(cfine, 1, tmpcrse, 1, nc)

    call destroy(tmpcrse)

    call destroy(tmpla)

    do i = 1, nboxes(cfine)
       if ( remote(cfine, i) ) cycle

       cbx = get_ibox(cfine,i)
       fine_box = get_ibox(fine,i)
       fbx = grow(fine_box,ng)
       fbx =  box_intersection(fbx,periodic_domain_box)

       cslope_lo(1:dm) = lwb(grow(cbx, -1))
       cslope_hi(1:dm) = upb(grow(cbx, -1))

!      local_bc(:,:,1:nc) = bc_fine%adv_bc_level_array(i,:,:,bcomp:bcomp+nc-1)

       local_bc(:,:,1:nc) = INTERIOR

                if (cslope_lo(1) == crse_domain%lo(1)) then
                   local_bc(1,1,1:nc) = bc_crse%adv_bc_level_array(0,1,1,bcomp:bcomp+nc-1)
                end if
                if (cslope_hi(1) == crse_domain%hi(1)) then
                   local_bc(1,2,1:nc) = bc_crse%adv_bc_level_array(0,1,2,bcomp:bcomp+nc-1)
                end if
                if (dm > 1) then
                   if (cslope_lo(2) == crse_domain%lo(2)) then
                      local_bc(2,1,1:nc) = bc_crse%adv_bc_level_array(0,2,1,bcomp:bcomp+nc-1)
                   end if
                   if (cslope_hi(2) == crse_domain%hi(2)) then
                      local_bc(2,2,1:nc) = bc_crse%adv_bc_level_array(0,2,2,bcomp:bcomp+nc-1)
                   end if
                end if
                if (dm > 2) then
                   if (cslope_lo(dm) == crse_domain%lo(dm)) then
                      local_bc(dm,1,1:nc) = bc_crse%adv_bc_level_array(0,dm,1,bcomp:bcomp+nc-1)
                   end if
                   if (cslope_hi(dm) == crse_domain%hi(dm)) then
                      local_bc(dm,2,1:nc) = bc_crse%adv_bc_level_array(0,dm,2,bcomp:bcomp+nc-1)
                   end if
                end if


       lo_c(1:dm) = lwb(cbx)
       hi_c(1:dm) = upb(cbx)

       lo_f(1:dm) = lwb(fbx)
       hi_f(1:dm) = upb(fbx)

       allocate(fp(lo_f(1):hi_f(1),lo_f(2):hi_f(2),1:1,1:nc))

       allocate(fvcx(lo_f(1):hi_f(1)+1))
       forall (j = lo_f(1):hi_f(1)+1) fvcx(j) = dble(j)
       if (dm > 1) then
          allocate(fvcy(lo_f(2):hi_f(2)+1))
          forall (j = lo_f(2):hi_f(2)+1) fvcy(j) = dble(j) 
          if (dm > 2) then
             allocate(fvcz(lo_f(3):hi_f(3)+1))
             forall (j = lo_f(3):hi_f(3)+1) fvcy(j) = dble(j)
          end if
       end if

       allocate(cvcx(lo_c(1):hi_c(1)+1))
       forall (j = lo_c(1):hi_c(1)+1) cvcx(j) = dble(j) * TWO
       if (dm > 1) then
          allocate(cvcy(lo_c(2):hi_c(2)+1))
          forall (j = lo_c(2):hi_c(2)+1) cvcy(j) = dble(j) * TWO
          if (dm > 2) then
             allocate(cvcz(lo_c(3):hi_c(3)+1))
             forall (j = lo_c(3):hi_c(3)+1) cvcz(j) = dble(j) * TWO
          end if
       end if

       src => dataptr(cfine, i)

       select case (dm)
       case (2)
          call lin_cc_interp_2d(fp(:,:,1,:), lo_f, src(:,:,1,:), lo_c, ir, local_bc, &
             fvcx, lo_f(1), fvcy, lo_f(2), &
             cvcx, lo_c(1), cvcy, lo_c(2), &
             cslope_lo, cslope_hi, lim_slope, lin_limit)
       case (3)
          call lin_cc_interp_3d(fp(:,:,:,:), lo_f, src(:,:,:,:), lo_c, ir, local_bc, &
               fvcx, lo_f(1), fvcy, lo_f(2), fvcz, lo_f(3), &
               cvcx, lo_c(1), cvcy, lo_c(2), cvcz, lo_c(3), &
               cslope_lo, cslope_hi, lim_slope, lin_limit)
       end select

       dst => dataptr(fine,  i, fbx, icomp, nc)

       dst = fp

       deallocate(cvcx, fvcx, fp)
       if (dm > 1) deallocate(cvcy, fvcy)
       if (dm > 2) deallocate(cvcz, fvcz)

    end do

    call multifab_physbc(fine,icomp,bcomp,nc,dx,bc_fine)

    call destroy(la)
    call destroy(cfine)

  end subroutine

end module fillpatch_module
