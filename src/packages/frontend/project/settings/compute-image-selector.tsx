/*
 *  This file is part of CoCalc: Copyright © 2020 Sagemath, Inc.
 *  License: AGPLv3 s.t. "Commons Clause" – see LICENSE.md for details
 */

// This is for selecting the "standard" compute images Ubuntu XX.YY, etc.

import { DownOutlined } from "@ant-design/icons";
import { Col, Row } from "@cocalc/frontend/antd-bootstrap";
import { useTypedRedux } from "@cocalc/frontend/app-framework";
import { Icon, Loading, Space } from "@cocalc/frontend/components";
import { unreachable } from "@cocalc/util/misc";
import { COLORS } from "@cocalc/util/theme";
import { Button, Dropdown, Menu } from "antd";
import { fromJS } from "immutable";
import type { MenuProps } from "antd";
type MenuItem = Required<MenuProps>["items"][number];

const title = (x) => x.get("short") ?? x.get("title") ?? x.get("id") ?? "";

const cmp_title = (a, b) => {
  const t1: string = title(a);
  const t2: string = title(b);
  return t1.toLowerCase() < t2.toLowerCase() ? 1 : -1;
};

// we want "Default", "Previous", ... to come first, hence "order" trumps "short" title
const img_sorter = (a, b): number => {
  const o1 = a.get("order", 0);
  const o2 = b.get("order", 0);
  if (o1 == o2) {
    return cmp_title(a, b);
  }
  return o1 > o2 ? 1 : -1;
};

interface ComputeImageSelectorProps {
  selected_image: string;
  layout: "vertical" | "horizontal";
  onBlur?: () => void;
  onFocus?: () => void;
  onSelect: (e) => void;
}

export const ComputeImageSelector: React.FC<ComputeImageSelectorProps> = (
  props: ComputeImageSelectorProps
) => {
  const { selected_image, onFocus, onBlur, onSelect, layout } = props;

  /*
  software_envs = {
    "groups": [
      "Legacy",
      "Standard"
    ],
    "default": "ubuntu2004-1",
    "environments": {
      "ubuntu1804": {
        "id": "ubuntu1804",
        "group": "Legacy",
        "registry": "docker.io/my-cocalc-registry",
        "tag": "project-1804-20220101",
        "title": "Ubuntu 18.04",
        "descr": ""
      },
      ...
    }
*/
  const software_envs = useTypedRedux("customize", "software");

  if (software_envs == null) {
    return <Loading />;
  }

  const COMPUTE_IMAGES = fromJS(software_envs.get("environments")).sort(
    img_sorter
  );

  const DEFAULT_COMPUTE_IMAGE = software_envs.get("default");
  const GROUPS: string[] = software_envs.get("groups").toJS();

  function compute_image_info(name, type) {
    return COMPUTE_IMAGES.getIn([name, type]);
  }

  const default_title = compute_image_info(DEFAULT_COMPUTE_IMAGE, "title");
  const selected_title = compute_image_info(selected_image, "title");

  function render_menu_children(group: string): MenuItem[] {
    return COMPUTE_IMAGES.filter(
      (item) => item.get("group") === group && !item.get("hidden", false)
    )
      .map((img, key) => ({
        key,
        title: img.get("descr"),
        label: img.get("short") ?? img.get("title"),
      }))
      .valueSeq()
      .toJS();
  }

  function render_menu_group(group: string): MenuItem {
    return {
      key: group,
      children: render_menu_children(group),
      label: group,
      type: "group",
    };
  }

  function menu_items(): MenuProps["items"] {
    return GROUPS.map(render_menu_group);
  }

  function render_menu() {
    return (
      <Menu
        onClick={(e) => onSelect(e.key)}
        style={{ maxHeight: "400px", overflowY: "auto" }}
        items={menu_items()}
      />
    );
  }

  function render_selector() {
    return (
      <Dropdown overlay={render_menu()}>
        <Button onBlur={onBlur} onFocus={onFocus}>
          {selected_title} <DownOutlined />
        </Button>
      </Dropdown>
    );
  }

  function render_doubt() {
    if (selected_image === DEFAULT_COMPUTE_IMAGE) {
      return undefined;
    } else {
      return (
        <span style={{ color: COLORS.GRAY, fontSize: "11pt" }}>
          <br /> (If in doubt, select "{default_title}")
        </span>
      );
    }
  }

  function render_info(italic: boolean) {
    const desc = compute_image_info(selected_image, "descr");
    return <span>{italic ? <i>{desc}</i> : desc}</span>;
  }

  switch (layout) {
    case "vertical":
      // used in project settings → project control
      return (
        <Col xs={12}>
          <Row style={{ fontSize: "12pt" }}>
            <Icon name={"hdd"} />
            <Space />
            Selected image
            <Space />
            {render_selector()}
            <Space />
            {render_doubt()}
          </Row>
          <Row>{render_info(true)}</Row>
        </Col>
      );
    case "horizontal":
      // used in projects → create new project
      return (
        <Col xs={12}>
          <Icon name={"hdd"} />
          <Space />
          <span style={{ fontSize: "12pt", fontWeight: "bold" }}>
            {render_selector()}
          </span>
          <span style={{ marginLeft: "10px" }}>{render_info(false)}</span>
        </Col>
      );
    default:
      unreachable(layout);
      return null;
  }
};
