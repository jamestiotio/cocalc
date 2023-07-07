/*
React component used from edit-license for editing the PurchaseInfo about one
single license.  It doesn't manage actually coordinating purchases, showing prices
or anything like that.
*/

import type { PurchaseInfo } from "@cocalc/util/licenses/purchase/types";
import type { Changes } from "@cocalc/util/purchases/cost-to-edit-license";
import { Alert, DatePicker, InputNumber, Switch, Select, Table } from "antd";
import dayjs from "dayjs";
import { MAX } from "@cocalc/util/licenses/purchase/consts";

interface Props {
  info: PurchaseInfo;
  onChange: (info: PurchaseInfo) => void;
  style?;
}

const columns = [
  {
    title: <div style={{ textAlign: "center" }}>Field</div>,
    dataIndex: "field",
    key: "field",
    render: (field) => <div style={{ margin: "15px" }}>{field}</div>,
  },
  {
    title: <div style={{ textAlign: "center" }}>Value</div>,
    dataIndex: "value",
    key: "value",
    render: (field) => <div style={{ margin: "15px" }}>{field}</div>,
  },
];

export default function LicenseEditor({ info, onChange, style }: Props) {
  const handleFieldChange = (field: keyof Changes) => (value: any) => {
    if (field == "start" || field == "end") {
      value = value?.toDate();
    }
    onChange({ ...info, [field]: value });
  };

  if (info.type == "vouchers") {
    return <Alert type="error" message="Editing vouchers is not allowed." />;
  }

  const isSubscription = info.subscription != null && info.subscription != "no";

  const data = [
    {
      key: "1",
      field: "Start Date",
      value: (
        <DatePicker
          disabled={
            (info.start != null && info.start <= new Date()) || isSubscription
          }
          value={info.start ? dayjs(info.start) : undefined}
          onChange={handleFieldChange("start")}
          disabledDate={(current) => current < dayjs().startOf("day")}
        />
      ),
    },
    {
      key: "2",
      field: "End Date",
      value: (
        <div>
          <DatePicker
            disabled={isSubscription}
            value={info.end ? dayjs(info.end) : undefined}
            onChange={handleFieldChange("end")}
            disabledDate={(current) => current <= dayjs().startOf("day")}
          />
          {isSubscription && (
            <div style={{ color: "#666", marginTop: "15px" }}>
              Editing the end date of a subscription license is not allowed.
            </div>
          )}
        </div>
      ),
    },

    ...(info.type == "quota"
      ? [
          {
            key: "3",
            field: "Run Limit",
            value: (
              <InputNumber
                min={1}
                step={1}
                value={info.quantity}
                onChange={handleFieldChange("quantity")}
                addonAfter={"Projects"}
              />
            ),
          },
          {
            key: "4",
            field: "RAM",
            value: (
              <InputNumber
                min={1}
                max={MAX.ram}
                step={1}
                value={info.custom_ram}
                onChange={handleFieldChange("custom_ram")}
                addonAfter={"GB"}
              />
            ),
          },
          {
            key: "5",
            field: "Disk",
            value: (
              <InputNumber
                min={1}
                max={MAX.disk}
                step={1}
                value={info.custom_disk}
                onChange={handleFieldChange("custom_disk")}
                addonAfter={"GB"}
              />
            ),
          },
          {
            key: "6",
            field: "CPU",
            value: (
              <InputNumber
                min={1}
                max={MAX.cpu}
                step={1}
                value={info.custom_cpu}
                onChange={handleFieldChange("custom_cpu")}
                addonAfter={"Shared vCPU"}
              />
            ),
          },
          {
            key: "7",
            field: "Member Hosting",
            value: (
              <Switch
                checked={info.custom_member}
                onChange={handleFieldChange("custom_member")}
              />
            ),
          },
          {
            key: "8",
            field: "Idle Timeout",
            value: (
              <Select
                style={{ width: "100%" }}
                value={info.custom_uptime}
                onChange={handleFieldChange("custom_uptime")}
              >
                <Select.Option value="short">Short (30 minutes)</Select.Option>
                <Select.Option value="medium">Medium (2 hours)</Select.Option>
                <Select.Option value="day">Day (24 hours)</Select.Option>
                <Select.Option value="always_running">
                  Always Running
                </Select.Option>
              </Select>
            ),
          },
        ]
      : []),
  ];

  return (
    <Table
      bordered
      style={style}
      columns={columns}
      dataSource={data}
      pagination={false}
    />
  );
}
