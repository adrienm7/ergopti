// .cpanel-ci.js

import { deploy, excludeDefaults } from "@samkirkland/ftp-deploy";

async function deployToCPanel() {
  console.log("🚚 Deploy started");
  await deploy({
    server: process.env.FTP_SERVER,
    username: process.env.FTP_USERNAME,
    password: process.env.FTP_PASSWORD,
   "local-dir": "./build/",
    timeout: 600000,
    "dry-run": false,
    protocol: "ftps",
    exclude: [...excludeDefaults, ".env", ".git/**", "node_modules/**", "vendor/**"],
  });
  console.log("🚀 Deploy done!");
}

deployToCPanel();