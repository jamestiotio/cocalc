/*
 *  This file is part of CoCalc: Copyright © 2020 Sagemath, Inc.
 *  License: AGPLv3 s.t. "Commons Clause" – see LICENSE.md for details
 */
import { useActions, useTypedRedux } from "../app-framework";
import { Alert, Button } from "../antd-bootstrap";
import { A, Icon, Loading } from "../components";
import { HelpEmailLink } from "../customize";
import { location } from "./util";
import { DISCORD_INVITE } from "@cocalc/util/theme";
import { appBasePath } from "@cocalc/frontend/customize/app-base-path";
import { join } from "path";

export function infoLink(sub: string = ""): string {
  return join(appBasePath, "info", sub);
}

export const SupportInfo: React.FC = () => {
  const url = useTypedRedux("support", "url");
  const err = useTypedRedux("support", "err");
  const project_title = useTypedRedux("support", "project_title");
  const status = useTypedRedux("support", "status");
  const actions = useActions("support");
  const hide_extra_info = useTypedRedux("support", "hide_extra_info");

  function render_error() {
    return (
      <Alert bsStyle="danger" style={{ fontWeight: "bold" }}>
        <p>
          Sorry, there has been an error creating the ticket.
          <br />
          Please email <HelpEmailLink /> directly! (NOTE: You can click "Help"
          again to reopen the support ticket form and copy your content to
          email.)
        </p>
        <p>Error message:</p>
        <pre>{err}</pre>
      </Alert>
    );
  }

  function render_created() {
    return (
      <div style={{ textAlign: "center" }}>
        <p>
          Ticket has been created successfully. Keep this link in order to stay
          in contact with us:
        </p>
        <p style={{ fontSize: "120%" }}>
          {url ? <A href={url}>{url}</A> : "no ticket"}
        </p>
        <Button
          bsStyle="success"
          style={{ marginTop: "3em" }}
          tabIndex={4}
          onClick={actions.new_ticket}
        >
          Create New Ticket
        </Button>
      </div>
    );
  }

  function render_default() {
    const how = (
      <p>
        After submitting a ticket, you{"'"}ll receive a link, which you should
        save until you receive a confirmation email. You can also check the
        status of your ticket under "Support" in your account settings. We
        typically respond to support requests from paying customers very
        quickly.{" "}
        <i>
          NOTE: unless you have specifically purchased a support contract, we
          are under no contractual obligation to respond to support requests,
          and reserve the right to close them unanswered.
        </i>
      </p>
    );
    if (hide_extra_info) return how;
    let what;
    const title = project_title;
    const bugs = (
      <b>
        We want to know about{" "}
        <A href="https://github.com/sagemathinc/cocalc/issues?q=is%3Aissue+is%3Aopen+label%3AI-bug">
          every bug in CoCalc!
        </A>
      </b>
    );

    if (title != null) {
      const loc = location();
      const fn = loc.slice(47); // / projects / uuid /
      what = (
        <p>
          If you have a problem involving <code>"{fn}"</code> in the project{" "}
          <code>"{title}"</code>, please create a support ticket below. {bugs}
        </p>
      );
    } else {
      what = (
        <p>
          If you have a problem involving a specific project or file, close this
          dialog, navigate to that file, then click on <Icon name="medkit" /> in
          the top right corner to open it again. Otherwise, please fill out this
          form. {bugs}
        </p>
      );
    }
    return (
      <div>
        <h2 style={{ marginTop: "-5px" }}>
          <A href={join(appBasePath, "info")}>Information</A>
        </h2>
        <ul>
          <li>
            <A href={join(appBasePath, "info")}>
              <Icon name="external-link" />{" "}
              <b>More documentation and help...</b>
            </A>
          </li>
          <li>
            <A href="https://doc.cocalc.com/howto/missing-project.html">
              File or project gone?
            </A>
          </li>
          <li>
            Jupyter notebook or SageMath worksheet{" "}
            <A href="https://doc.cocalc.com/howto/slow-worksheet.html">slow</A>{" "}
            or{" "}
            <A href="https://doc.cocalc.com/howto/jupyter-kernel-terminated.html">
              crashing?
            </A>
          </li>
          <li>
            <A href="https://doc.cocalc.com/howto/sage-question.html">
              Questions about SageMath?
            </A>
          </li>
          <li>
            <b>
              Hit a bug, just need to talk with us, or request that we install
              software:
            </b>{" "}
            Create a support ticket below...
          </li>
          <li>
            Just <b>want to quickly chat</b>? Visit{" "}
            <A href={DISCORD_INVITE}>the CoCalc Discord server</A>!
          </li>
        </ul>

        <h2>Create a support ticket</h2>
        <p>
          <b>NOTE:</b> Support is in English and German only.
        </p>

        {what}

        {how}
      </div>
    );
  }

  switch (status) {
    case "error":
      return render_error();
    case "creating":
      return <Loading />;
    case "created":
      return render_created();
    default:
      return render_default();
  }
};
