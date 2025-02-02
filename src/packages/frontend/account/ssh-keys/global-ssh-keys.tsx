/*
 *  This file is part of CoCalc: Copyright © 2020 Sagemath, Inc.
 *  License: AGPLv3 s.t. "Commons Clause" – see LICENSE.md for details
 */

import { Col, Row } from "../../antd-bootstrap";
import { redux, useRedux } from "@cocalc/frontend/app-framework";
import { A } from "../../components";
import { SSHKeyAdder } from "./ssh-key-adder";
import { SSHKeyList } from "./ssh-key-list";
import { Footer } from "@cocalc/frontend/customize";

export const SSHKeysPage: React.FC = () => {
  const ssh_keys = useRedux("account", "ssh_keys");

  function render_pre_list_message() {
    return (
      <div style={{ marginTop: "10px", marginBottom: "10px", color: "#444" }}>
        The global SSH keys listed here allow you to connect from your computer
        via SSH to{" "}
        <b>
          <i>all projects</i>
        </b>{" "}
        on which you are an owner or collaborator. Alternatively, set SSH keys
        that grant access only to a project in the settings for that project.
        See the SSH part of the settings page in a project for further
        instructions.
      </div>
    );
  }

  function help() {
    return (
      <div>
        To SSH into a project, use the following{" "}
        <span style={{ color: "#666" }}>username@host:</span>
        <pre>[project-id-without-dashes]@ssh.cocalc.com </pre>
        The project id without dashes can be found in the part of project
        settings about SSH keys. To SSH between projects, use{" "}
        <pre>[project-id-without-dashes]@ssh</pre>
      </div>
    );
  }

  return (
    <div style={{ marginTop: "1em" }}>
      <Row>
        <Col md={8}>
          {render_pre_list_message()}
          <SSHKeyList help={help()} ssh_keys={ssh_keys} />
        </Col>
        <Col md={4}>
          <SSHKeyAdder
            add_ssh_key={(opts) =>
              redux.getActions("account").add_ssh_key(opts)
            }
            style={{ marginBottom: "0px" }}
          />
          <div style={{ marginTop: "10px" }}>
            <A href="https://github.com/sagemathinc/cocalc/wiki/AllAboutProjects#create-ssh-key">
              How to create SSH Keys...
            </A>
          </div>
        </Col>
      </Row>
      <Footer />
    </div>
  );
};
