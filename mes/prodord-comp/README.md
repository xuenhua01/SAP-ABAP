# Z_CN_PP_PRODORD_COMP_UPDATE

MES 调用 SAP，按生产订单插入或删除组件。函数入参 `I_JSON_IN`，出参 `E_JSON_OUT`。处理结果写入日志表 `ZCNPPT0040`。

同一张工单、同一个 `ID` 的多行是一笔。这一笔里有一行失败，整笔不保存。该工单和 `ID` 已经成功过的，不能再传。

## 报文

```json
{
  "Header": {
    "InterfaceCode": "product change",
    "RequestTime": "20261106 161100"
  },
  "RequestInfo": {
    "ShippedPackage": [
      {
        "WipOrderNo": "10000000378",
        "ID": "202611070001",
        "ProductNo": "3066899",
        "IssueQuantity": "2",
        "UomCode": "EA",
        "OprSequenceNo": "0020",
        "ItemNo": "0014",
        "ChangeCode": "2"
      }
    ]
  }
}
```

| 字段 | 含义 |
| --- | --- |
| WipOrderNo | 生产订单，内部按 `AUFNR` 补前导零 |
| ID | 业务唯一号。与工单一起防重 |
| ProductNo | 组件物料 |
| IssueQuantity | 数量。只在插入时使用 |
| UomCode | 单位。插入时必须等于该物料 `MARA` 基本单位 |
| OprSequenceNo | 工序，对应 `VORNR` |
| ItemNo | 删除时是预留行 `RSPOS`，即屏幕上「预留」旁边的号 |
| ChangeCode | `1` 插入，`2` 删除 |

返回在 `Header`：`IsSuccess`、`ErrorCode`、`ErrorMsg`、`RequestTime`、`ResponseTime`、`WipOrderNo`。

## 插入

`ChangeCode = 1`。

报文里的 `ItemNo` 不参与编号。屏幕「项目」`POSNR` 取该订单已有最大号加 10，写入组件。预留号用生产订单自己的 `AFKO-RSNUM`，报文不能指定，函数也不能改。预留行由 SAP 在新增组件时自己编。

单位与 `MARA-MEINS` 不一致时，这一笔失败，不改订单。

## 删除

`ChangeCode = 2`。

用订单预留号、物料、报文 `ItemNo`（预留行）找未删除的组件。先读入订单缓冲，再按缓冲索引删除。保存后如果该预留行还在，返回「删除未生效」。

## 使用的函数

- `CO_XT_COMPONENT_ADD`：插入组件
- `CO_BT_RESB_UPDATE`：把自动编号的屏幕项目写回缓冲
- `CO_XT_COMPONENT_FIND`、`CO_BT_RESB_READ_WITH_KEY`、`CO_BT_RESB_DELETE`：按缓冲索引删除
- `CO_ZV_ORDER_POST`：保存订单，并关闭成本核算对话框
- `BAPI_TRANSACTION_COMMIT` / `BAPI_TRANSACTION_ROLLBACK`

## 日志表

`ZCNPPT0040`，字段见 `ZCNPPT0040_SE11.txt`。主键是订单号加 `GUID`。业务防重看订单号、`ID`、`STATUS = 1`。

## 源码

`Z_CN_PP_PRODORD_COMP_UPDATE.abap` 是当前系统在用的函数源码。激活函数名是 `Z_CN_PP_PRODORD_COMP_UPDATE`。
