/*
 *  This file is part of CoCalc: Copyright © 2020 Sagemath, Inc.
 *  License: AGPLv3 s.t. "Commons Clause" – see LICENSE.md for details
 */

/* Search input box with the following capabilities
   a clear button (that focuses the input)
   - `enter` to submit
   - `esc` to clear
*/

import { Input, InputRef } from "antd";
import { React, useEffect, useState, useRef } from "../app-framework";

interface Props {
  size?;
  default_value?: string;
  value?: string;
  on_change?: (value: string, opts: { ctrl_down: boolean }) => void;
  on_clear?: () => void;
  on_submit?: (value: string, opts: { ctrl_down: boolean }) => void;
  buttonAfter?: JSX.Element;
  disabled?: boolean;
  clear_on_submit?: boolean;
  on_down?: () => void;
  on_up?: () => void;
  on_escape?: (value: string) => void;
  style?: React.CSSProperties;
  input_class?: string;
  autoFocus?: boolean;
  autoSelect?: boolean;
  placeholder?: string;
  focus?: number; // if this changes, focus the search box.
}

export const SearchInput: React.FC<Props> = React.memo((props) => {
  const [value, set_value] = useState<string>(
    props.value ?? props.default_value ?? ""
  );
  // if value changes, we update as well!
  useEffect(() => set_value(props.value ?? ""), [props.value]);

  const [ctrl_down, set_ctrl_down] = useState<boolean>(false);

  const input_ref = useRef<InputRef>(null);

  useEffect(() => {
    if (props.autoSelect && input_ref.current) {
      try {
        input_ref.current?.select();
      } catch (_) {}
    }
  }, []);

  useEffect(() => {
    if (focus == null) return;
    input_ref.current?.focus();
  }, [focus]);

  function get_opts(): { ctrl_down: boolean } {
    return { ctrl_down };
  }

  function clear_value(): void {
    set_value("");
    props.on_change?.("", get_opts());
    props.on_clear?.();
  }

  function submit(e?): void {
    if (e != null) {
      e.preventDefault();
    }
    if (typeof props.on_submit === "function") {
      props.on_submit(value, get_opts());
    }
    if (props.clear_on_submit) {
      clear_value();
      props.on_change?.(value, get_opts());
    }
  }

  function key_down(e): void {
    switch (e.keyCode) {
      case 27:
        escape();
        break;
      case 40:
        props.on_down?.();
        break;
      case 38:
        props.on_up?.();
        break;
      case 17:
        set_ctrl_down(true);
        break;
      case 13:
        submit();
        break;
    }
  }

  function key_up(e): void {
    switch (e.keyCode) {
      case 17:
        set_ctrl_down(false);
        break;
    }
  }

  function escape(): void {
    if (typeof props.on_escape === "function") {
      props.on_escape(value);
    }
    clear_value();
  }

  return (
    <Input.Search
      size={props.size}
      allowClear
      style={{ minWidth: "150px", ...props.style }}
      cocalc-test="search-input"
      autoFocus={props.autoFocus}
      ref={input_ref}
      type="text"
      placeholder={props.placeholder}
      value={value}
      onChange={(e) => {
        e.preventDefault();
        const value = e.target?.value ?? "";
        set_value(value);
        props.on_change?.(value, get_opts());
        if (!value) clear_value();
      }}
      onKeyDown={key_down}
      onKeyUp={key_up}
      disabled={props.disabled}
      enterButton={props.buttonAfter}
    />
  );
});
