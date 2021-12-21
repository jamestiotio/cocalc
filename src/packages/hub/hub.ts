//########################################################################
// This file is part of CoCalc: Copyright © 2020 Sagemath, Inc.
// License: AGPLv3 s.t. "Commons Clause" – see LICENSE.md for details
//########################################################################

// This is the CoCalc Global HUB.  It runs as a daemon, sitting in the
// middle of the action, connected to potentially thousands of clients,
// many Sage sessions, and PostgreSQL database.

import { spawn } from "child_process";
import { COCALC_MODES } from "@cocalc/server/projects/control";
import blocked from "blocked";
import { program as commander, Option } from "commander";
import { callback2 } from "@cocalc/util/async-utils";
import { callback } from "awaiting";
import { getLogger } from "./logger";
import { init as initMemory } from "@cocalc/backend/memory";
import basePath from "@cocalc/backend/base-path";
import { retry_until_success } from "@cocalc/util/async-utils";
const { COOKIE_OPTIONS } = require("./client"); // import { COOKIE_OPTIONS } from "./client";
import { init_passport } from "./auth";
import { init_start_always_running_projects } from "@cocalc/database/postgres/always-running";
import { set_agent_endpoint } from "./health-checks";
import initHandleMentions from "@cocalc/server/mentions/handle";
const MetricsRecorder = require("./metrics-recorder"); // import * as MetricsRecorder from "./metrics-recorder";
import { start as startHubRegister } from "./hub_register";
import { getClients } from "./clients";
import { stripe_sync } from "@cocalc/server/stripe/sync";
import port from "@cocalc/backend/port";
import { database } from "./servers/database";
import initExpressApp from "./servers/express-app";
import initHttpRedirect from "./servers/http-redirect";
import initDatabase from "./servers/database";
import initProjectControl from "@cocalc/server/projects/control";
import initIdleTimeout from "@cocalc/server/projects/control/stop-idle-projects";
import initVersionServer from "./servers/version";
import initPrimus from "./servers/primus";
import { load_server_settings_from_env } from "@cocalc/server/settings/server-settings";

// Logger tagged with 'hub' for this file.
const winston = getLogger("hub");

// program gets populated with the command line options below.
let program: { [option: string]: any } = {};
export { program };

// How frequently to register with the database that this hub is up and running,
// and also report number of connected clients.
const REGISTER_INTERVAL_S = 20;

// the jsmap of connected clients
const clients = getClients();

async function reset_password(email_address: string): Promise<void> {
  try {
    await callback2(database.reset_password, { email_address });
    winston.info(`Password changed for ${email_address}`);
  } catch (err) {
    winston.info(`Error resetting password -- ${err}`);
  }
}

// This calculates and updates the statistics for the /stats endpoint.
// It's important that we call this periodically, because otherwise the /stats data is outdated.
async function init_update_stats(): Promise<void> {
  winston.info("init updating stats periodically");
  const update = () => callback2(database.get_stats);
  // Do it every minute:
  setInterval(() => update(), 60000);
  // Also do it once now:
  await update();
}

// This calculates and updates the site_license_usage_log.
// It's important that we call this periodically, if we want
// to be able to monitor site license usage. This is enabled
// by default only for dev mode (so for development).
async function init_update_site_license_usage_log() {
  winston.info("init updating site license usage log periodically");
  const update = async () => await database.update_site_license_usage_log();
  setInterval(update, 31000);
  await update();
}

async function initMetrics() {
  winston.info("Initializing Metrics Recorder...");
  await callback(MetricsRecorder.init, winston);
  return {
    metric_blocked: MetricsRecorder.new_counter(
      "blocked_ms_total",
      'accumulates the "blocked" time in the hub [ms]'
    ),
    uncaught_exception_total: MetricsRecorder.new_counter(
      "uncaught_exception_total",
      'counts "BUG"s'
    ),
  };
}

async function startServer(): Promise<void> {
  winston.info("start_server");

  // Be very sure cookies do NOT work unless over https.  IMPORTANT.
  if (!COOKIE_OPTIONS.secure) {
    throw Error("client cookie options are not secure");
  }

  winston.info(`basePath='${basePath}'`);
  winston.info(
    `using database "${program.keyspace}" and database-nodes="${program.databaseNodes}"`
  );

  const { metric_blocked, uncaught_exception_total } = await initMetrics();

  // Log anything that blocks the CPU for more than 10ms -- see https://github.com/tj/node-blocked
  blocked((ms: number) => {
    if (ms > 0) {
      metric_blocked.inc(ms);
    }
    // record that something blocked:
    winston.debug(`BLOCKED for ${ms}ms`);
  });

  // Log heap memory usage info
  initMemory(winston.debug);

  // Wait for database connection to work.  Everything requires this.
  await retry_until_success({
    f: async () => await callback2(database.connect),
    start_delay: 1000,
    max_delay: 10000,
  });
  winston.info("connected to database.");

  if (program.updateDatabaseSchema) {
    winston.info("Update database schema");
    await callback2(database.update_schema);

    // in those cases where we initialize the database upon startup
    // (essentially only relevant for kucalc's hub-websocket)
    // set server settings based on environment variables
    if (program.mode === "kucalc") {
      await load_server_settings_from_env(database);
    }
  }

  if (program.agentPort) {
    winston.info("Configure agent port");
    set_agent_endpoint(program.agentPort, program.hostname);
  }

  // Mentions
  if (program.mentions) {
    winston.info("enabling handling of mentions...");
    initHandleMentions();
  }

  // Project control
  winston.info("initializing project control...");
  const projectControl = initProjectControl(program.mode);
  // used for nextjs hot module reloading dev server
  process.env["COCALC_MODE"] = program.mode;

  if (program.mode != "kucalc" && program.websocketServer) {
    // We handle idle timeout of projects.
    // This can be disabled via COCALC_NO_IDLE_TIMEOUT.
    // This only uses the admin-configurable settings field of projects
    // in the database and isn't aware of licenses or upgrades.
    initIdleTimeout(projectControl);
  }

  if (program.websocketServer) {
    // Initialize the version server -- must happen after updating schema
    // (for first ever run).
    await initVersionServer();

    if (program.mode == "single-user" && process.env.USER == "user") {
      // Definitely in dev mode, probably on cocalc.com in a project, so we kill
      // all the running projects when starting the hub:
      // Whenever we start the dev server, we just assume
      // all projects are stopped, since assuming they are
      // running when they are not is bad.  Something similar
      // is done in cocalc-docker.
      winston.info("killing all projects...");
      await callback2(database._query, {
        safety_check: false,
        query: 'update projects set state=\'{"state":"opened"}\'',
      });
      await spawn("pkill", ["-f", "node_modules/.bin/cocalc-project"]);

      // Also, unrelated to killing projects, for purposes of developing
      // custom software images, we inject a couple of random nonsense entries
      // into the table in the DB:
      winston.info("inserting random nonsense compute images in database");
      await callback2(database.insert_random_compute_images);
    }

    if (program.mode != "kucalc") {
      await init_update_stats();
      await init_update_site_license_usage_log();
      // This is async but runs forever, so don't wait for it.
      winston.info("init starting always running projects");
      init_start_always_running_projects(database);
    }
  }

  const { router, httpServer } = await initExpressApp({
    isPersonal: program.personal,
    projectControl,
    proxyServer: !!program.proxyServer,
    nextServer: !!program.nextServer,
    cert: program.httpsCert,
    key: program.httpsKey,
  });

  // The express app create via initExpressApp above **assumes** that init_passport is done
  // or complains a lot. This is obviously not really necessary, but we leave it for now.
  await callback2(init_passport, {
    router,
    database,
    host: program.hostname,
  });

  winston.info(`starting webserver listening on ${program.hostname}:${port}`);
  await callback(httpServer.listen.bind(httpServer), port, program.hostname);

  if (port == 443 && program.httpsCert && program.httpsKey) {
    // also start a redirect from port 80 to port 443.
    await initHttpRedirect(program.hostname);
  }

  if (program.websocketServer) {
    winston.info("initializing primus websocket server");
    initPrimus({
      httpServer,
      router,
      projectControl,
      clients,
      host: program.hostname,
      isPersonal: program.personal,
    });
  }

  if (program.websocketServer || program.proxyServer || program.nextServer) {
    winston.info(
      "Starting registering periodically with the database and updating a health check..."
    );

    // register the hub with the database periodically, and
    // also confirms that database is working.
    await callback2(startHubRegister, {
      database,
      clients,
      host: program.hostname,
      port,
      interval_s: REGISTER_INTERVAL_S,
    });

    const msg = `Started HUB!\n*****\n\n ${
      program.httpsKey ? "https" : "http"
    }://${program.hostname}:${port}${basePath}\n\n*****`;
    winston.info(msg);
  }

  addErrorListeners(uncaught_exception_total);
}

// addErrorListeners: after successful startup, don't crash on routine errors.
// We don't do this until startup, since we do want to crash on errors on startup.
// TODO: could alternatively be handled via winston (?).
function addErrorListeners(uncaught_exception_total) {
  process.addListener("uncaughtException", function (err) {
    winston.error(
      "BUG ****************************************************************************"
    );
    winston.error("Uncaught exception: " + err);
    console.error(err.stack);
    winston.error(err.stack);
    winston.error(
      "BUG ****************************************************************************"
    );
    database?.uncaught_exception(err);
    uncaught_exception_total.inc(1);
  });

  return process.on("unhandledRejection", function (reason, p) {
    winston.error(
      "BUG UNHANDLED REJECTION *********************************************************"
    );
    console.error(p, reason); // strangely sometimes winston.error can't actually show the traceback...
    winston.error("Unhandled Rejection at:", p, "reason:", reason);
    winston.error(
      "BUG UNHANDLED REJECTION *********************************************************"
    );
    database?.uncaught_exception(p);
    uncaught_exception_total.inc(1);
  });
}

//############################################
// Process command line arguments
//############################################
async function main(): Promise<void> {
  const default_db = process.env.PGHOST ?? "localhost";
  commander
    .name("cocalc-hub-server")
    .usage("options")
    .addOption(
      new Option(
        "--mode [string]",
        `REQUIRED mode in which to run CoCalc (${COCALC_MODES.join(
          ", "
        )}) - or set COCALC_MODE env var`
      ).choices(COCALC_MODES)
    )
    .option(
      "--all",
      "runs all of the servers: websocket, proxy, next (so you don't have to pass all those opts separately), and also mentions updator and updates db schema on startup; use this in situations where there is a single hub that serves everything (instead of a microservice situation like kucalc)"
    )
    .option("--websocket-server", "run the websocket server")
    .option("--proxy-server", "run the proxy server")
    .option(
      "--next-server",
      "run the nextjs server (landing pages, share server, etc.)"
    )
    /*.option("--https", "if specified will use (or create selfsigned) data/https/key.pem and data/https/cert.pem and serve https on the port specified by the PORT env variable. Do not combine this with --https-key/--htps-cert options below.")*/
    .option(
      "--https-key [string]",
      "serve over https.  argument should be a key filename (both https-key and https-cert must be specified)"
    )
    .option(
      "--https-cert [string]",
      "serve over https.  argument should be a cert filename (both https-key and https-cert must be specified)"
    )
    .option(
      "--agent-port <n>",
      "port for HAProxy agent-check (default: 0 -- do not start)",
      (n) => parseInt(n),
      0
    )
    .option(
      "--hostname [string]",
      'host of interface to bind to (default: "127.0.0.1")',
      "127.0.0.1"
    )
    .option(
      "--database-nodes <string,string,...>",
      `database address (default: '${default_db}')`,
      default_db
    )
    .option(
      "--keyspace [string]",
      'Database name to use (default: "smc")',
      "smc"
    )
    .option("--passwd [email_address]", "Reset password of given user", "")
    .option(
      "--update-database-schema",
      "If specified, updates database schema on startup (always happens when mode is not kucalc)."
    )
    .option(
      "--stripe-sync",
      "Sync stripe subscriptions to database for all users with stripe id",
      "yes"
    )
    .option(
      "--update-stats",
      "Calculates the statistics for the /stats endpoint and stores them in the database",
      "yes"
    )
    .option("--delete-expired", "Delete expired data from the database", "yes")
    .option(
      "--blob-maintenance",
      "Do blob-related maintenance (dump to tarballs, offload to gcloud)",
      "yes"
    )
    .option("--mentions", "if given, periodically handle mentions")
    .option(
      "--test",
      "terminate after setting up the hub -- used to test if it starts up properly"
    )
    .option(
      "--db-concurrent-warn <n>",
      "be very unhappy if number of concurrent db requests exceeds this (default: 300)",
      (n) => parseInt(n),
      300
    )
    .option(
      "--personal",
      "run VERY UNSAFE: there is only one user and no authentication"
    )
    .parse(process.argv);
  // Everywhere else in our code, we just refer to program.[options] since we
  // wrote this code against an ancient version of commander.
  const opts = commander.opts();
  for (const name in opts) {
    program[name] = opts[name];
  }
  if (!program.mode) {
    program.mode = process.env.COCALC_MODE;
    if (!program.mode) {
      throw Error(
        `the --mode option must be specified or the COCALC_MODE env var set to one of ${COCALC_MODES.join(
          ", "
        )}`
      );
      process.exit(1);
    }
  }
  if (program.all) {
    program.websocketServer =
      program.proxyServer =
      program.nextServer =
      program.mentions =
      program.updateDatabaseSchema =
        true;
  }

  //console.log("got opts", opts);

  try {
    // Everything we do here requires the database to be initialized. Once
    // this is called, require('@cocalc/database/postgres/database').default() is a valid db
    // instance that can be used.
    initDatabase({
      host: program.databaseNodes,
      database: program.keyspace,
      concurrent_warn: program.dbConcurrentWarn,
    });

    if (program.passwd) {
      winston.debug("Resetting password");
      await reset_password(program.passwd);
      process.exit();
    } else if (program.stripeSync) {
      winston.debug("Stripe sync");
      await stripe_sync({ database, logger: winston });
      process.exit();
    } else if (program.deleteExpired) {
      await callback2(database.delete_expired, {
        count_only: false,
      });
      process.exit();
    } else if (program.blobMaintenance) {
      await callback2(database.blob_maintenance);
      process.exit();
    } else if (program.updateStats) {
      await callback2(database.get_stats);
      process.exit();
    } else {
      await startServer();
    }
  } catch (err) {
    console.log(err);
    winston.error("Error -- ", err);
    process.exit(1);
  }
}

main();
