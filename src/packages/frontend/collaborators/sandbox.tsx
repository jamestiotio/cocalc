/*
 *  This file is part of CoCalc: Copyright © 2020 Sagemath, Inc.
 *  License: AGPLv3 s.t. "Commons Clause" – see LICENSE.md for details
 */

/*
Manage tokens that can be used to add new users who
know the token to a project.

TODO:
- we don't allow adjusting the usage_limit, so hide that for now.
- the default expire time is "2 weeks" and user can't edit that yet, except to set expire to now.

*/

// Load the code that checks for the PROJECT_INVITE_QUERY_PARAM
// when user gets signed in, and handles it.

import { useState } from "react";
import { Checkbox, Popconfirm } from "antd";
import { CopyToClipBoard, Icon } from "../components";
import { join } from "path";
import { appBasePath } from "@cocalc/frontend/customize/app-base-path";
import { webapp_client } from "../webapp-client";
import { redux } from "@cocalc/frontend/app-framework";
import { Map } from "immutable";

interface Props {
  project?: Map<string, any>;
}

export default function Sandbox({ project }: Props) {
  const [expanded, setExpanded] = useState<boolean>(false);

  if (
    project == null ||
    project.getIn(["users", webapp_client.account_id, "group"]) != "owner"
  ) {
    // only owners can configure this settings.
    // TODO: right now we are only enforcing this via the UI on the frontend.
    // This isn't a huge issue, since a sandbox project is a free-for-all afterall.
    return <></>;
  }

  const heading = (
    <div>
      <a
        onClick={() => {
          setExpanded(!expanded);
        }}
        style={{ cursor: "pointer" }}
      >
        {" "}
        <Icon
          style={{ width: "20px" }}
          name={expanded ? "caret-down" : "caret-right"}
        />{" "}
        {project?.get("sandbox") ? (
          <b>This is a Public Sandbox Project...</b>
        ) : (
          "Make this a public sandbox project..."
        )}
      </a>
    </div>
  );
  if (!expanded) {
    return heading;
  }

  function render_link() {
    if (!project?.get("sandbox")) {
      return (
        <div>
          <p>
            If you make this project a public sandbox project, then you can
            share any URL in your project and when somebody visits that URL they
            will automatically be added as a collaborator to your project. All
            collaborators who are not the owner will be removed if they are not
            active for about 10 minutes. Any trial, member hosting, and network
            banners are also not visible.
          </p>
          <p>
            Only do this if you have <b>very minimal security requirements</b>{" "}
            for the content of this project.
          </p>
        </div>
      );
    }
    return (
      <div>
        <p>Share this URL, or the URL of any file in your project:</p>
        <CopyToClipBoard
          value={`${document.location.origin}${join(
            appBasePath,
            "projects"
          )}/${project?.get("project_id")}`}
          style={{ width: "100%", marginBottom: "15px" }}
        />
        <p>
          When somebody with an account visits that URL, they will automatically
          be added as a collaborator to this project.
        </p>
      </div>
    );
  }

  return (
    <div>
      {heading}
      <div
        style={{
          border: "1px solid #eee",
          borderRadius: "5px",
          padding: "15px",
          marginTop: "5px",
        }}
      >
        {project.get("sandbox") ? (
          <Checkbox
            checked
            onChange={() => {
              redux
                .getActions("projects")
                .set_project_sandbox(project.get("project_id"), false);
            }}
          >
            Public Sandbox Project
          </Checkbox>
        ) : (
          <Popconfirm
            title={
              <div style={{ maxWidth: "350px" }}>
                Are you absolutely sure? Only do this if you have very minimal
                security requirements for the content of this project.
                <br />
                NOTE: You can always disable sandbox mode later, remove any
                collaborators that were added, and collaborators can't delete
                backups or TimeTravel history.
              </div>
            }
            onConfirm={() => {
              redux
                .getActions("projects")
                .set_project_sandbox(project.get("project_id"), true);
            }}
            okText={"Yes, make this a public sandbox project!"}
            cancelText={"Cancel"}
          >
            <Checkbox checked={false}>Public Sandbox Project</Checkbox>
          </Popconfirm>
        )}
        <br />
        <br />
        {render_link()}
      </div>
    </div>
  );
}
