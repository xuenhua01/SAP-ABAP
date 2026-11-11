FUNCTION z_cn_pp_prodord_comp_update.
*"----------------------------------------------------------------------
*"*"本地接口：
*"  IMPORTING
*"     VALUE(I_JSON_IN) TYPE  STRING OPTIONAL
*"  EXPORTING
*"     VALUE(E_JSON_OUT) TYPE  STRING
*"----------------------------------------------------------------------
*" MES→SAP 生产订单组件更新
*" 结构：RequestInfo-ShippedPackage[]（行上带 WipOrderNo+ID，可多订单）
*" 按 订单+ID 分组独立处理；表 ZCNPPT0040
*" 单位必须等于该物料 MARA 基本单位
*" OprSequenceNo=VORNR(工序)
*" 删除：ItemNo=预留行 RSPOS（屏上「预留」旁边的号，不是「项目」POSNR）
*" 插入：POSNR 按已有最大+10自动累加；报文 ItemNo 不参与编号
*"----------------------------------------------------------------------

  TYPE-POOLS: coxt.

  TYPES: BEGIN OF typ_header,
           interfacecode TYPE string,
           requesttime   TYPE string,
         END OF typ_header.

  TYPES: BEGIN OF typ_ship_item,
           wiporderno    TYPE string,
           id            TYPE string,
           productno     TYPE string,
           issuequantity TYPE string,
           uomcode       TYPE string,
           oprsequenceno TYPE string, " VORNR
           itemno        TYPE string, " 删除=预留行 RSPOS；插入不使用
           changecode    TYPE string, " 1插入 2删除
         END OF typ_ship_item.
  TYPES: typ_t_ship TYPE STANDARD TABLE OF typ_ship_item WITH DEFAULT KEY.

  TYPES: BEGIN OF typ_requestinfo,
           shippedpackage TYPE typ_t_ship,
         END OF typ_requestinfo.

  TYPES: BEGIN OF typ_import,
           header      TYPE typ_header,
           requestinfo TYPE typ_requestinfo,
         END OF typ_import.

  TYPES: BEGIN OF typ_header_out,
           interfacecode TYPE string,
           issuccess     TYPE string,
           errorcode     TYPE string,
           errormsg      TYPE string,
           requesttime   TYPE string,
           responsetime  TYPE string,
           wiporderno    TYPE string,
         END OF typ_header_out.

  TYPES: BEGIN OF typ_export,
           header TYPE typ_header_out,
         END OF typ_export.

  TYPES: BEGIN OF typ_grp,
           aufnr TYPE aufnr,
           id    TYPE zcnppt0040-id,
         END OF typ_grp.

  DATA: lv_json_in TYPE string.
  DATA: rec_import TYPE typ_import.

  DATA: lt_log     TYPE TABLE OF zcnppt0040,
        lt_log_one TYPE TABLE OF zcnppt0040,
        ls_log     TYPE zcnppt0040.

  DATA: lv_json_out TYPE string.
  DATA: rec_export  TYPE typ_export.

  DATA: lv_mesg    TYPE string.
  DATA: lv_out_msg TYPE string.
  DATA: lv_errflg  TYPE char1.
  DATA: lv_any_err TYPE char1.
  DATA: lv_aufnrs  TYPE string.

  DATA: lt_grp TYPE TABLE OF typ_grp,
        ls_grp TYPE typ_grp.

*---- 业务/接口类型（严格对齐 COXT 类型池 + 表字段）--------------------*
  DATA: lv_aufnr     TYPE aufnr,
        lv_matnr18   TYPE c LENGTH 18,          " 强制18位补零（对齐MARC内码）
        lv_matnr     TYPE matnr,                " 查MARC/RESB
        lv_material  TYPE coxt_material,        " = mara-matnr，给CO_XT
        lv_vornr     TYPE vornr,                " CHAR4 NUMCV
        lv_rspos     TYPE rspos,                " NUMC4 查RESB
        lv_posno     TYPE cif_r3res-positionno, " CHAR6 = I_POSNO
        lv_postp     TYPE resb-postp,           " I_POSTP
        lv_werks     TYPE werks_d,
        lv_rsnum     TYPE rsnum,
        lv_aufpl     TYPE afko-aufpl,
        lv_lgort     TYPE lgort_d,
        lv_aplzl     TYPE afvc-aplzl,
        lv_batch_sav  TYPE sy-batch,            " 压弹窗：暂存 sy-batch
        lv_binpt_sav  TYPE sy-binpt,            " 压弹窗：暂存 sy-binpt
        lv_resb_idx   TYPE sy-tabix,
        lv_meins_base TYPE meins,               " MARA 基本单位
        lv_posnr_max  TYPE resb-posnr,          " 已有最大屏幕项目号 POSNR
        lv_posnr_num  TYPE i,
        lv_posnr_next TYPE resb-posnr.          " 本次自动累加 POSNR

  DATA: ls_ord_key   TYPE coxt_ord_key,
        ls_requ_quan TYPE coxt_s_quantity,
        ls_stor      TYPE coxt_s_storage_location,
        ls_storx     TYPE coxt_s_storage_locationx,
        ls_bapiret   TYPE coxt_bapireturn,
        lv_xt_err    TYPE c,
        ls_resbd     TYPE resbd,
        lt_resbdel   TYPE coxt_t_resbdel,
        ls_resbdel   LIKE LINE OF lt_resbdel,
        lt_xt_ret    TYPE coxt_t_bapireturn,
        ls_comp_key  TYPE coxt_s_ord_comp_key,
        ls_xt        TYPE LINE OF coxt_t_bapireturn.

*---------------------------------------------------------------------*
* JSON 解析
*---------------------------------------------------------------------*
  CLEAR: lv_json_in, rec_import, lt_log, lt_grp, lv_any_err, lv_out_msg, lv_aufnrs.
  lv_json_in = i_json_in.
  /ui2/cl_json=>deserialize( EXPORTING json = lv_json_in
                              CHANGING data = rec_import ).

*---------------------------------------------------------------------*
* 0. 摊平行 → lt_log，收集 订单+ID
*---------------------------------------------------------------------*
  LOOP AT rec_import-requestinfo-shippedpackage ASSIGNING FIELD-SYMBOL(<fs_in>).

    CLEAR: ls_log, lv_matnr18, lv_matnr, lv_vornr, lv_rspos.

    ls_log-zcsrq = rec_import-header-requesttime+0(8).
    IF strlen( rec_import-header-requesttime ) >= 15.
      ls_log-zcssj = rec_import-header-requesttime+9(6).
    ELSE.
      ls_log-zcssj = sy-uzeit.
    ENDIF.

*   订单号：报文是 string，模板 ALPHA=IN 不会补零，必须走 ALPHA_INPUT
    CALL FUNCTION 'CONVERSION_EXIT_ALPHA_INPUT'
      EXPORTING
        input  = <fs_in>-wiporderno
      IMPORTING
        output = ls_log-aufnr.
    ls_log-id = <fs_in>-id.

*   物料：输出落到 CHAR18，再赋给 MATNR —— 保证是18位内码
    CALL FUNCTION 'CONVERSION_EXIT_MATN1_INPUT'
      EXPORTING
        input        = <fs_in>-productno
      IMPORTING
        output       = lv_matnr18
      EXCEPTIONS
        length_error = 1
        OTHERS       = 2.
    IF sy-subrc <> 0 OR lv_matnr18 IS INITIAL.
      lv_matnr18 = |{ <fs_in>-productno ALPHA = IN }|.
    ENDIF.
    lv_matnr     = lv_matnr18.
    ls_log-matnr = lv_matnr.

    ls_log-bdmng = <fs_in>-issuequantity.

    lv_vornr     = |{ <fs_in>-oprsequenceno ALPHA = IN }|.
    ls_log-vornr = lv_vornr.

    lv_rspos     = <fs_in>-itemno.
    ls_log-posnr = lv_rspos.

    ls_log-zchange = <fs_in>-changecode.

*   单位：按报文 UomCode 转内码
    CLEAR ls_log-meins.
    CALL FUNCTION 'CONVERSION_EXIT_CUNIT_INPUT'
      EXPORTING
        input          = <fs_in>-uomcode
      IMPORTING
        output         = ls_log-meins
      EXCEPTIONS
        unit_not_found = 1
        OTHERS         = 2.
    IF sy-subrc <> 0.
      ls_log-meins = <fs_in>-uomcode.
    ENDIF.

    TRY.
        ls_log-guid = cl_system_uuid=>create_uuid_c32_static( ).
      CATCH cx_root.
        CLEAR ls_log-guid.
    ENDTRY.

    APPEND ls_log TO lt_log.

    CLEAR ls_grp.
    ls_grp-aufnr = ls_log-aufnr.
    ls_grp-id    = ls_log-id.
    APPEND ls_grp TO lt_grp.
  ENDLOOP.

  SORT lt_grp BY aufnr id.
  DELETE ADJACENT DUPLICATES FROM lt_grp COMPARING aufnr id.

  IF lt_log IS INITIAL.
    lv_any_err = 'X'.
    lv_out_msg = '组件明细为空'.
  ENDIF.

*=====================================================================*
* 按每个 订单+ID 独立处理
*=====================================================================*
  LOOP AT lt_grp INTO ls_grp.

    CLEAR: lt_log_one, lv_errflg, lv_mesg, lv_aufnr, lv_werks,
           lv_rsnum, lv_aufpl, lv_lgort.

    lv_aufnr = ls_grp-aufnr.

    IF lv_aufnrs IS INITIAL.
      lv_aufnrs = |{ lv_aufnr ALPHA = OUT }|.
    ELSE.
      lv_aufnrs = lv_aufnrs && '|' && |{ lv_aufnr ALPHA = OUT }|.
    ENDIF.

    LOOP AT lt_log INTO ls_log
                    WHERE aufnr = ls_grp-aufnr
                      AND id    = ls_grp-id.
      APPEND ls_log TO lt_log_one.
    ENDLOOP.

*-------------------------------------------------------------------*
* 头校验 + 防重（AUFNR+ID 且 STATUS=1）
*-------------------------------------------------------------------*
    IF lv_aufnr IS INITIAL OR ls_grp-id IS INITIAL.
      lv_errflg = 'X'.
      lv_mesg   = '工单号或唯一ID为空'.
    ENDIF.

    IF lv_errflg IS INITIAL.
      SELECT SINGLE status
        FROM zcnppt0040
        INTO @DATA(lv_st)
       WHERE aufnr  = @lv_aufnr
         AND id     = @ls_grp-id
         AND status = '1'.
      IF sy-subrc = 0.
        lv_errflg = 'X'.
        lv_mesg   = |订单{ lv_aufnr ALPHA = OUT }+ID已成功，请勿重复传输|.
      ENDIF.
    ENDIF.

    IF lv_errflg IS INITIAL.
      SELECT SINGLE aufnr, werks
        FROM aufk
        INTO (@DATA(lv_db_aufnr), @lv_werks)
       WHERE aufnr = @lv_aufnr.
      IF sy-subrc <> 0.
        lv_errflg = 'X'.
        lv_mesg   = |生产订单 { lv_aufnr ALPHA = OUT } 不存在|.
      ENDIF.
    ENDIF.

    IF lv_errflg IS INITIAL.
      SELECT SINGLE rsnum, aufpl
        FROM afko
        INTO (@lv_rsnum, @lv_aufpl)
       WHERE aufnr = @lv_aufnr.
      IF sy-subrc <> 0 OR lv_rsnum IS INITIAL.
        lv_errflg = 'X'.
        lv_mesg   = |生产订单 { lv_aufnr ALPHA = OUT } 预留号读取失败|.
      ENDIF.
    ENDIF.

    IF lv_errflg IS INITIAL.
      SELECT SINGLE lgort
        FROM resb
        INTO @lv_lgort
       WHERE rsnum = @lv_rsnum
         AND lgort <> @space.
    ENDIF.

*-------------------------------------------------------------------*
* 行校验
*-------------------------------------------------------------------*
    IF lv_errflg IS INITIAL.

      LOOP AT lt_log_one ASSIGNING FIELD-SYMBOL(<fs_log>).

        CLEAR: lv_matnr18, lv_matnr, lv_vornr, lv_rspos.

        CALL FUNCTION 'CONVERSION_EXIT_MATN1_INPUT'
          EXPORTING
            input        = <fs_log>-matnr
          IMPORTING
            output       = lv_matnr18
          EXCEPTIONS
            length_error = 1
            OTHERS       = 2.
        IF sy-subrc <> 0 OR lv_matnr18 IS INITIAL.
          lv_matnr18 = |{ <fs_log>-matnr ALPHA = IN }|.
        ENDIF.
        lv_matnr       = lv_matnr18.
        <fs_log>-matnr = lv_matnr.
        lv_vornr       = <fs_log>-vornr.
        lv_rspos       = <fs_log>-posnr.

        IF <fs_log>-zchange <> '1' AND <fs_log>-zchange <> '2'.
          <fs_log>-status = '0'.
          lv_mesg = |更新标识必须是1或2，物料 { lv_matnr ALPHA = OUT }|.
          IF <fs_log>-message IS INITIAL.
            <fs_log>-message = lv_mesg.
          ELSE.
            <fs_log>-message = <fs_log>-message && '/' && lv_mesg.
          ENDIF.
          CLEAR lv_mesg.
        ENDIF.

        SELECT SINGLE matnr
          FROM marc
          INTO @DATA(lv_marc)
         WHERE matnr = @lv_matnr
           AND werks = @lv_werks.
        IF sy-subrc <> 0.
          <fs_log>-status = '0'.
          lv_mesg = |物料 { lv_matnr ALPHA = OUT } 工厂 { lv_werks } 在MARC不存在|.
          IF <fs_log>-message IS INITIAL.
            <fs_log>-message = lv_mesg.
          ELSE.
            <fs_log>-message = <fs_log>-message && '/' && lv_mesg.
          ENDIF.
          CLEAR lv_mesg.
        ENDIF.

*       单位必须等于该物料 MARA 基本单位
        IF <fs_log>-status IS INITIAL AND <fs_log>-zchange = '1'.
          SELECT SINGLE meins
            FROM mara
            INTO @lv_meins_base
           WHERE matnr = @lv_matnr.
          IF sy-subrc <> 0 OR lv_meins_base IS INITIAL.
            <fs_log>-status = '0'.
            lv_mesg = |物料 { lv_matnr ALPHA = OUT } 基本单位读取失败|.
          ELSEIF <fs_log>-meins <> lv_meins_base.
            <fs_log>-status = '0'.
            lv_mesg = |单位必须等于物料基本单位{ lv_meins_base }，报文单位{ <fs_log>-meins }|.
          ENDIF.
          IF lv_mesg IS NOT INITIAL.
            IF <fs_log>-message IS INITIAL.
              <fs_log>-message = lv_mesg.
            ELSE.
              <fs_log>-message = <fs_log>-message && '/' && lv_mesg.
            ENDIF.
            CLEAR lv_mesg.
          ENDIF.
        ENDIF.

*       删除：ItemNo = 预留行 RSPOS（屏上「预留」旁边的号）
        IF <fs_log>-zchange = '2'.
          CLEAR lv_rspos.
          CALL FUNCTION 'CONVERSION_EXIT_ALPHA_INPUT'
            EXPORTING
              input  = <fs_log>-posnr
            IMPORTING
              output = lv_rspos.
          <fs_log>-posnr = lv_rspos.
          SELECT SINGLE rsnum
            FROM resb
            INTO @DATA(lv_rsnum_chk)
           WHERE rsnum = @lv_rsnum
             AND matnr = @lv_matnr
             AND rspos = @lv_rspos
             AND xloek = @space.
          IF sy-subrc <> 0.
            <fs_log>-status = '0'.
            lv_mesg = |删除失败：组件不存在 物料{ lv_matnr ALPHA = OUT } 预留行{ lv_rspos }|.
            IF <fs_log>-message IS INITIAL.
              <fs_log>-message = lv_mesg.
            ELSE.
              <fs_log>-message = <fs_log>-message && '/' && lv_mesg.
            ENDIF.
            CLEAR lv_mesg.
          ENDIF.
        ENDIF.

        IF <fs_log>-status IS NOT INITIAL.
          lv_errflg = 'X'.
        ENDIF.

      ENDLOOP.

    ENDIF.

*-------------------------------------------------------------------*
* 改生产订单组件（CO_XT 入参全部用接口同名类型）
*-------------------------------------------------------------------*
    IF lv_errflg IS INITIAL.

*     接口少弹窗：batch + binpt（SE37有界面时仍可能弹标准 MESSAGE，无法100%禁）
      lv_batch_sav = sy-batch.
      lv_binpt_sav = sy-binpt.
      sy-batch     = abap_true.
      sy-binpt     = abap_true.
      CALL FUNCTION 'CO_XT_TRACE_DISABLE'.
      CALL FUNCTION 'CO_XT_ORDER_INITIALIZE'.

*     项目号起点：本单已有最大 POSNR（按 10 递增，与 CO02 常见编号一致）
      CLEAR: lv_posnr_max, lv_posnr_num, lv_posnr_next.
      SELECT MAX( posnr )
        FROM resb
        INTO @lv_posnr_max
       WHERE rsnum = @lv_rsnum
         AND xloek = @space.
      IF lv_posnr_max IS INITIAL.
        lv_posnr_num = 0.
      ELSE.
        lv_posnr_num = lv_posnr_max.
      ENDIF.

      LOOP AT lt_log_one INTO ls_log.

        CLEAR: ls_bapiret, lv_xt_err, ls_requ_quan, ls_stor, ls_storx,
               ls_resbd, lt_resbdel, lt_xt_ret, ls_comp_key, lv_aplzl, ls_xt,
               lv_matnr18, lv_matnr, lv_material, lv_vornr, lv_rspos, lv_posno,
               lv_posnr_next.
        CLEAR lv_postp.
        lv_postp   = 'L'.
        ls_ord_key = lv_aufnr.

        CALL FUNCTION 'CONVERSION_EXIT_MATN1_INPUT'
          EXPORTING
            input        = ls_log-matnr
          IMPORTING
            output       = lv_matnr18
          EXCEPTIONS
            length_error = 1
            OTHERS       = 2.
        IF sy-subrc <> 0 OR lv_matnr18 IS INITIAL.
          lv_matnr18 = |{ ls_log-matnr ALPHA = IN }|.
        ENDIF.
        lv_matnr    = lv_matnr18.
        lv_material = lv_matnr.                 " coxt_material
        lv_vornr    = ls_log-vornr.
        lv_rspos    = ls_log-posnr.

        IF ls_log-zchange = '1'.
          SELECT SINGLE aplzl
            FROM afvc
            INTO @lv_aplzl
           WHERE aufpl = @lv_aufpl
             AND vornr = @lv_vornr.
          IF sy-subrc <> 0.
            lv_errflg = 'X'.
            lv_mesg   = |工序号 { lv_vornr } 在订单中不存在|.
            EXIT.
          ENDIF.

*         自动累加项目号：最大 POSNR + 10（整数不能用 ALPHA，用 UNPACK 补零）
          lv_posnr_num = lv_posnr_num + 10.
          UNPACK lv_posnr_num TO lv_posnr_next.
          ls_log-posnr = lv_posnr_next.
          CALL FUNCTION 'CONVERSION_EXIT_ALPHA_INPUT'
            EXPORTING
              input  = lv_posnr_next
            IMPORTING
              output = lv_posno.

          ls_requ_quan-quantity = ls_log-bdmng.
          ls_requ_quan-uom      = ls_log-meins.
*         coxt_s_storage_location 字段是 werks/lgort（不是 plant/stge_loc）
          ls_stor-werks  = lv_werks.
          ls_stor-lgort  = lv_lgort.
          ls_storx-werks = 'X'.
          IF lv_lgort IS NOT INITIAL.
            ls_storx-lgort = 'X'.
          ENDIF.

          CALL FUNCTION 'CO_XT_COMPONENT_ADD'
            EXPORTING
              is_order_key         = ls_ord_key
              i_material           = lv_material
              is_requ_quan         = ls_requ_quan
              i_operation          = lv_aplzl
              is_storage_location  = ls_stor
              is_storage_locationx = ls_storx
              i_postp              = lv_postp
              i_posno              = lv_posno
            IMPORTING
              es_bapireturn        = ls_bapiret
              e_error_occurred     = lv_xt_err
              es_resbd_created     = ls_resbd.

          IF lv_xt_err IS NOT INITIAL OR ls_bapiret-type CA 'AEX'.
            lv_errflg = 'X'.
            lv_mesg   = |插入组件失败：{ ls_bapiret-message }|.
            EXIT.
          ENDIF.

*         I_POSNO→STPOZ；屏幕「项目」= POSNR，必须回写自动累加号
          CLEAR lv_resb_idx.
          CALL FUNCTION 'CO_BT_RESB_READ_WITH_KEY'
            EXPORTING
              flg_resbd       = 'X'
              no_maktx        = 'X'
              no_statxt       = 'X'
              rsnum_imp       = ls_resbd-rsnum
              rspos_imp       = ls_resbd-rspos
              rsart_imp       = ls_resbd-rsart
              no_read_from_db = 'X'
            IMPORTING
              resbd_exp       = ls_resbd
              index_exp       = lv_resb_idx
            EXCEPTIONS
              not_found       = 1
              OTHERS          = 2.
          IF sy-subrc = 0 AND lv_resb_idx IS NOT INITIAL.
            ls_resbd-posnr = lv_posnr_next.
            CALL FUNCTION 'CO_BT_RESB_UPDATE'
              EXPORTING
                resb_new  = ls_resbd
                tabix_old = lv_resb_idx.
          ENDIF.

*         回写日志里的项目号
          MODIFY lt_log_one FROM ls_log TRANSPORTING posnr WHERE guid = ls_log-guid.
          MODIFY lt_log FROM ls_log TRANSPORTING posnr WHERE guid = ls_log-guid.

        ELSE.
*         ItemNo = 预留行 RSPOS；按订单预留号 + 预留行定位后再删
          CLEAR lv_rspos.
          CALL FUNCTION 'CONVERSION_EXIT_ALPHA_INPUT'
            EXPORTING
              input  = ls_log-posnr
            IMPORTING
              output = lv_rspos.
          SELECT SINGLE rsnum, rspos, rsart
            FROM resb
            INTO (@ls_comp_key-rsnum, @ls_comp_key-rspos, @ls_comp_key-rsart)
           WHERE rsnum = @lv_rsnum
             AND matnr = @lv_matnr
             AND rspos = @lv_rspos
             AND xloek = @space.
          IF sy-subrc <> 0.
            lv_errflg = 'X'.
            lv_mesg   = |删除时找不到组件 物料{ lv_matnr ALPHA = OUT } 预留行{ lv_rspos }|.
            EXIT.
          ENDIF.

*         CO_XT_COMPONENTS_DELETE 在缓冲行号(INDBT)为空时直接当成功返回，库不变
*         先读入订单，再按缓冲索引调 CO_BT_RESB_DELETE
          CLEAR: ls_bapiret, lv_xt_err, ls_resbd, lv_resb_idx.
          CALL FUNCTION 'CO_XT_COMPONENT_FIND'
            EXPORTING
              i_order_key      = ls_ord_key
              is_ord_comp_key  = ls_comp_key
            IMPORTING
              es_bapireturn    = ls_bapiret
              e_error_occurred = lv_xt_err.
          IF lv_xt_err IS NOT INITIAL.
            lv_errflg = 'X'.
            lv_mesg   = |删除前读入订单失败：{ ls_bapiret-message }|.
            EXIT.
          ENDIF.

          CALL FUNCTION 'CO_BT_RESB_READ_WITH_KEY'
            EXPORTING
              flg_resbd = 'X'
              no_maktx  = 'X'
              no_statxt = 'X'
              rsnum_imp = ls_comp_key-rsnum
              rspos_imp = ls_comp_key-rspos
              rsart_imp = ls_comp_key-rsart
            IMPORTING
              resbd_exp = ls_resbd
              index_exp = lv_resb_idx
            EXCEPTIONS
              not_found = 1
              OTHERS    = 2.
          IF sy-subrc <> 0 OR lv_resb_idx IS INITIAL.
            lv_errflg = 'X'.
            lv_mesg   = |删除时组件不在订单缓冲 物料{ lv_matnr ALPHA = OUT } 预留行{ lv_rspos }|.
            EXIT.
          ENDIF.

          CALL FUNCTION 'CO_BT_RESB_DELETE'
            EXPORTING
              flg_del = 'X'
              index   = lv_resb_idx
            EXCEPTIONS
              comp_not_found        = 1
              purchase_order_exists = 2
              delete_abort_error    = 3
              OTHERS                = 4.
          IF sy-subrc <> 0.
            lv_errflg = 'X'.
            lv_mesg   = |删除组件失败 SUBRC={ sy-subrc } 预留行{ lv_rspos }|.
            EXIT.
          ENDIF.
        ENDIF.

      ENDLOOP.

      IF lv_errflg IS INITIAL.
        CLEAR: ls_bapiret, lv_xt_err.
*       不用 CO_XT_ORDER_PREPARE_COMMIT：它调 CO_ZV 时没传 NO_DIALOG，
*       成本出错会弹「是否仍要保存」。这里直接调并关闭对话框。
        CALL FUNCTION 'CO_ZV_ORDER_POST'
          EXPORTING
            commit_flag    = space
            ext_flg        = 'X'
            trans_typ      = 'V'
            no_dialog      = 'X'
            no_gui_message = 'X'
          EXCEPTIONS
            no_change      = 1
            update_reject  = 2
            budget_reject  = 3
            text_error     = 4
            OTHERS         = 5.
        IF sy-subrc <> 0.
          lv_errflg = 'X'.
          MESSAGE ID sy-msgid TYPE sy-msgty NUMBER sy-msgno
                  WITH sy-msgv1 sy-msgv2 sy-msgv3 sy-msgv4
                  INTO lv_mesg.
          IF lv_mesg IS INITIAL.
            lv_mesg = |订单保存失败，SUBRC={ sy-subrc }|.
          ELSE.
            lv_mesg = |订单保存失败：{ lv_mesg }|.
          ENDIF.
          CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
        ELSE.
          CALL FUNCTION 'BAPI_TRANSACTION_COMMIT'
            EXPORTING
              wait = 'X'.
*         防止“接口成功但组件还在”
          LOOP AT lt_log_one INTO ls_log WHERE zchange = '2'.
            CLEAR lv_rspos.
            CALL FUNCTION 'CONVERSION_EXIT_ALPHA_INPUT'
              EXPORTING
                input  = ls_log-posnr
              IMPORTING
                output = lv_rspos.
            SELECT SINGLE rspos
              FROM resb
              INTO @DATA(lv_rspos_left)
             WHERE rsnum = @lv_rsnum
               AND matnr = @ls_log-matnr
               AND rspos = @lv_rspos
               AND xloek = @space.
            IF sy-subrc = 0.
              lv_errflg = 'X'.
              lv_mesg   = |删除未生效：物料{ ls_log-matnr ALPHA = OUT } 预留行{ lv_rspos }仍在订单上|.
              EXIT.
            ENDIF.
          ENDLOOP.
        ENDIF.
      ELSE.
        CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
      ENDIF.

      sy-batch = lv_batch_sav. " 恢复
      sy-binpt = lv_binpt_sav.

    ENDIF.

*-------------------------------------------------------------------*
* 本组回写
*-------------------------------------------------------------------*
    LOOP AT lt_log_one ASSIGNING <fs_log>.
      IF lv_errflg IS NOT INITIAL.
        <fs_log>-status = '0'.
        IF <fs_log>-message IS INITIAL.
          <fs_log>-message = lv_mesg.
        ENDIF.
      ELSE.
        <fs_log>-status  = '1'.
        <fs_log>-message = '成功'.
      ENDIF.
      MODIFY lt_log FROM <fs_log> TRANSPORTING status message
        WHERE aufnr = <fs_log>-aufnr
          AND id    = <fs_log>-id
          AND guid  = <fs_log>-guid.
    ENDLOOP.

    IF lt_log_one IS NOT INITIAL.
      MODIFY zcnppt0040 FROM TABLE lt_log_one.
    ENDIF.

    IF lv_errflg IS NOT INITIAL.
      lv_any_err = 'X'.
      IF lv_mesg IS NOT INITIAL.
        IF lv_out_msg IS INITIAL.
          lv_out_msg = lv_mesg.
        ELSE.
          lv_out_msg = lv_out_msg && '|' && lv_mesg.
        ENDIF.
      ELSE.
        LOOP AT lt_log_one ASSIGNING <fs_log> WHERE status = '0' AND message IS NOT INITIAL.
          IF lv_out_msg IS INITIAL.
            lv_out_msg = <fs_log>-message.
          ELSE.
            lv_out_msg = lv_out_msg && '|' && <fs_log>-message.
          ENDIF.
        ENDLOOP.
      ENDIF.
    ENDIF.

  ENDLOOP.

*---------------------------------------------------------------------*
* 返回
*---------------------------------------------------------------------*
  CLEAR rec_export.
  rec_export-header-interfacecode = rec_import-header-interfacecode.
  rec_export-header-requesttime   = rec_import-header-requesttime.
  rec_export-header-wiporderno    = lv_aufnrs.
  CONCATENATE sy-datlo sy-timlo INTO rec_export-header-responsetime SEPARATED BY space.

  IF lv_any_err IS NOT INITIAL.
    rec_export-header-issuccess = '0'.
    rec_export-header-errorcode = 'E'.
    IF lv_out_msg IS INITIAL.
      lv_out_msg = '失败'.
    ENDIF.
    rec_export-header-errormsg = lv_out_msg.
  ELSE.
    rec_export-header-issuccess = '1'.
    rec_export-header-errorcode = ''.
    rec_export-header-errormsg  = '成功'.
  ENDIF.

  lv_json_out = /ui2/cl_json=>serialize( data        = rec_export
                                         compress    = abap_true
                                         pretty_name = /ui2/cl_json=>pretty_mode-camel_case ).

  TRANSLATE lv_json_out TO LOWER CASE.
  REPLACE ALL OCCURRENCES OF 'header'        IN lv_json_out WITH 'Header'.
  REPLACE ALL OCCURRENCES OF 'interfacecode' IN lv_json_out WITH 'InterfaceCode'.
  REPLACE ALL OCCURRENCES OF 'issuccess'     IN lv_json_out WITH 'IsSuccess'.
  REPLACE ALL OCCURRENCES OF 'errorcode'     IN lv_json_out WITH 'ErrorCode'.
  REPLACE ALL OCCURRENCES OF 'errormsg'      IN lv_json_out WITH 'ErrorMsg'.
  REPLACE ALL OCCURRENCES OF 'requesttime'   IN lv_json_out WITH 'RequestTime'.
  REPLACE ALL OCCURRENCES OF 'responsetime'  IN lv_json_out WITH 'ResponseTime'.
  REPLACE ALL OCCURRENCES OF 'wiporderno'    IN lv_json_out WITH 'WipOrderNo'.

  e_json_out = lv_json_out.
  CLEAR lv_json_out.

ENDFUNCTION.
