import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

crons.interval("process google import jobs", { minutes: 2 }, internal.google.processQueuedSyncJobs, {});

export default crons;
