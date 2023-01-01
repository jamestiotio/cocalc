import {
  CSSProperties,
  useMemo,
  useRef,
  ReactNode,
  useCallback,
  useState,
} from "react";
import useViews, { View as ViewDescription } from "../syncdb/use-views";
import useViewControl from "../frame/use-view-control";
import { suggest_duplicate_filename } from "@cocalc/util/misc";
import { Button, Card, Dropdown, Input, Space, Tabs } from "antd";
import View from "./view";
import {
  SortableContext,
  verticalListSortingStrategy,
} from "@dnd-kit/sortable";
import { DndContext } from "@dnd-kit/core";
import { useSortable } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import { restrictToVerticalAxis } from "@dnd-kit/modifiers";
import { Icon, IconName } from "@cocalc/frontend/components";
import useViewsToggle from "./use-views-toggle";
import Handle from "../components/handle";

export const TYPE_TO_ICON: { [type: string]: IconName } = {
  grid: "table",
  gallery: "address-card",
  calendar: "calendar",
  kanban: "hdd",
};

interface TabItem {
  label: ReactNode;
  key: string;
  children: ReactNode;
  style?: CSSProperties;
}

const NEW = "__new__";

interface Props {
  table: string;
  style?: CSSProperties;
}

export default function Views({ table, style }: Props) {
  const { views, saveView, deleteView } = useViews(table);
  const { view, switchToView } = useViewControl(table, views?.[0]?.id);
  const { showViews, setShowViews } = useViewsToggle(table);

  const getView = useCallback(
    (id: string) => {
      if (views == null) return;
      for (const view of views) {
        if (view.id == id) {
          return view;
        }
      }
    },
    [views]
  );

  const items = useMemo(() => {
    const createNewView = (type: string) => {
      const newView = { type, id: undefined };
      saveView(newView);
      if (newView.id != null) {
        switchToView(newView.id);
      }
    };

    const items: TabItem[] = [];
    for (const { name, id, type } of views ?? []) {
      items.push({
        label: name,
        key: id,
        children: (
          <View
            table={table}
            view={type}
            name={name}
            id={id}
            style={{ height: "100%" }}
          />
        ),
        style: { height: "100%" },
      });
    }
    items.push({
      label: (
        <>
          <Icon
            name="plus-circle"
            style={{ fontSize: "15pt", margin: "0 5px 0 -24px" }}
          />
          {showViews && <> New View...</>}
        </>
      ),
      key: NEW,
      children: (
        <Card title="Create new view">
          <Space>
            <Button
              type="text"
              style={{ fontSize: "14pt" }}
              size="large"
              onClick={() => createNewView("grid")}
            >
              <Icon
                name={TYPE_TO_ICON["grid"]}
                style={{ marginRight: "15px" }}
              />{" "}
              Grid
            </Button>
            <Button
              type="text"
              style={{ fontSize: "14pt" }}
              size="large"
              onClick={() => createNewView("gallery")}
            >
              <Icon
                name={TYPE_TO_ICON["gallery"]}
                style={{ marginRight: "15px" }}
              />{" "}
              Gallery
            </Button>
            <Button
              type="text"
              style={{ fontSize: "14pt" }}
              size="large"
              onClick={() => createNewView("kanban")}
            >
              <Icon
                name={TYPE_TO_ICON["kanban"]}
                style={{ marginRight: "15px" }}
              />{" "}
              Kanban
            </Button>
            <Button
              type="text"
              style={{ fontSize: "14pt" }}
              size="large"
              onClick={() => createNewView("calendar")}
            >
              <Icon
                name={TYPE_TO_ICON["calendar"]}
                style={{ marginRight: "15px" }}
              />{" "}
              Calendar
            </Button>
          </Space>
        </Card>
      ),
    });
    return items;
  }, [views, showViews]);

  function handleDragEnd(event) {
    if (views == null) return;
    const { active, over, delta } = event;
    if (active.id !== over.id) {
      let activeIndex = 0;
      for (let j = 0; j < views.length; j++) {
        if (views[j].id == active.id) {
          activeIndex = j;
          break;
        }
      }
      for (let i = 0; i < views.length; i++) {
        if (views[i].id == over.id) {
          let pos;
          if (delta.y <= 0) {
            // before
            if (i == 0) {
              pos = views[i].pos - 1;
            } else {
              pos = (views[i].pos + views[i - 1].pos) / 2; // todo -- rescaling when too small.
            }
          } else {
            // after
            if (i == views.length - 1) {
              pos = views[i].pos + 1;
            } else {
              pos = (views[i].pos + views[i + 1].pos) / 2; // todo -- rescaling when too small.
            }
          }
          saveView({ ...views[activeIndex], pos });
          break;
        }
      }
    }
  }

  const renderTabBar = (tabBarProps, DefaultTabBar) => (
    <DndContext onDragEnd={handleDragEnd} modifiers={[restrictToVerticalAxis]}>
      <SortableContext
        items={items.map((node) => node.key)}
        strategy={verticalListSortingStrategy}
      >
        <DefaultTabBar {...tabBarProps}>
          {(node) =>
            node.key == NEW ? (
              node
            ) : (
              <SortableItem
                key={node.key}
                id={node.key}
                selected={view == node.key}
                getView={getView}
                showViews={showViews}
                setShowViews={setShowViews}
                onAction={(
                  action: "rename" | "duplicate" | "delete",
                  newName?: string
                ) => {
                  if (node.key == null) return;
                  const view = getView(`${node.key}`);
                  if (view == null) return;
                  if (action == "duplicate") {
                    const view2: Partial<ViewDescription> = { ...view };
                    delete view2.id;
                    delete view2.pos;
                    view2.name = suggest_duplicate_filename(
                      view2.name ?? "Copy"
                    );
                    saveView(view2);
                    return;
                  } else if (action == "rename") {
                    if (newName) {
                      saveView({ ...view, name: newName });
                    }
                    return;
                  } else if (action == "delete") {
                    deleteView(view);
                    return;
                  }
                }}
              >
                <Icon
                  style={{
                    fontSize: "15pt",
                    marginRight: "-15px",
                    color: view == node.key ? "#1677ff" : undefined,
                  }}
                  name={
                    TYPE_TO_ICON[getView(`${node.key}`)?.type ?? "grid"] ??
                    "square"
                  }
                />
                {showViews && node}
              </SortableItem>
            )
          }
        </DefaultTabBar>
      </SortableContext>
    </DndContext>
  );

  return (
    <Tabs
      tabPosition="left"
      activeKey={view}
      onChange={(view: string) => {
        switchToView(view);
      }}
      size="small"
      items={items}
      renderTabBar={renderTabBar}
      style={{ ...style, height: "100%" }}
    />
  );
}

export function SortableItem({
  id,
  children,
  selected,
  onAction,
  getView,
  showViews,
  setShowViews,
}) {
  const {
    attributes,
    listeners,
    setNodeRef,
    transform,
    transition,
    isDragging,
  } = useSortable({ id });

  const style = {
    transform: CSS.Transform.toString(transform),
    transition,
    height: "30px",
  };

  const width = showViews ? "150px" : "32px";

  const [editing, setEditing] = useState<boolean>(false);
  const inputRef = useRef<any>(null);

  // TODO: margins below and using rotated ellipsis is just cheap hack until grab a better "draggable" icon!
  return (
    <div ref={setNodeRef} style={style} {...attributes}>
      {editing ? (
        <Input
          autoFocus
          ref={inputRef}
          style={{ width, marginLeft: "12px" }}
          defaultValue={getView(id)?.name}
          onBlur={() => {
            const newName = inputRef.current?.input.value;
            setEditing(false);
            onAction("rename", newName);
          }}
          onPressEnter={() => {
            const newName = inputRef.current?.input.value;
            setEditing(false);
            onAction("rename", newName);
          }}
        />
      ) : (
        <div
          onClick={() => {
            if (selected) {
              setShowViews(!showViews);
            } else {
              setShowViews(true);
            }
          }}
          style={{
            width,
            display: "inline-block",
            overflow: "hidden",
            marginRight: "10px",
            boxShadow: isDragging
              ? "0 0 0 1px rgba(63, 63, 68, 0.05), 0px 15px 15px 0 rgba(34, 33, 81, 0.25)"
              : undefined,
          }}
        >
          {children}
        </div>
      )}
      {selected && showViews && (
        <span style={{ float: "right", marginRight: "10px" }}>
          <Dropdown
            trigger={["click"]}
            menu={{
              items: [
                {
                  key: "rename",
                  label: (
                    <span onClick={() => setEditing(true)}>
                      <Icon name="edit" style={{ marginRight: "10px" }} />
                      Rename view
                    </span>
                  ),
                },
                {
                  key: "duplicate",
                  label: (
                    <span onClick={() => onAction("duplicate")}>
                      <Icon name="copy" style={{ marginRight: "10px" }} />
                      Duplicate view
                    </span>
                  ),
                },
                {
                  key: "delete",
                  label: (
                    <span
                      style={{ color: "#ff4d4f" }}
                      onClick={() => onAction("delete")}
                    >
                      <Icon name="trash" style={{ marginRight: "10px" }} />
                      Delete view
                    </span>
                  ),
                },
              ],
            }}
          >
            <Icon name="caret-down" />
          </Dropdown>
          <span {...listeners}>
            <Handle />
          </span>
        </span>
      )}
    </div>
  );
}
