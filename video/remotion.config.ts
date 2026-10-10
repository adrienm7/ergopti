// video/remotion.config.ts
//
// Remotion CLI settings shared by the studio and every render. The public
// folder is video/public/, a set of links into the repository's static/
// created by scripts/prepare.mjs, so the driver windows render from their
// own files instead of copies.

import { Config } from '@remotion/cli/config';

Config.setVideoImageFormat('jpeg');
Config.setJpegQuality(92);
Config.setOverwriteOutput(true);
// Dashboards draw with Chart.js on a canvas; ANGLE keeps them GPU-accurate.
Config.setChromiumOpenGlRenderer('angle');
// The real driver windows load their scripts and fonts; leave them time on a
// cold cache before a frame is declared stuck.
Config.setDelayRenderTimeoutInMilliseconds(60000);
