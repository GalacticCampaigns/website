---
layout: default
title: Privacy Policy
---

# Privacy Policy for Galactic Campaigns

**Last Updated:** August 8, 2025

Your privacy is important to us. This Privacy Policy explains what information Galactic Campaigns ("the bot", "we", "us") collects, why we collect it, and how we use and protect that information when you use our services on the Discord platform.

By inviting and using Galactic Campaigns in your Discord server ("server", "guild"), you consent to the data practices described in this policy.

---
### **1. Information We Collect**

Galactic Campaigns is designed to be a structural tool and only collects data that is essential for its functionality. We do not store user messages. The information we collect can be categorized as follows:

* **Server (Guild) Information:**
    * **Server ID:** We store the unique ID of any server Galactic Campaigns is in. This is the primary key for all server-specific settings.
    * **Server Configurations:** We store all settings configured via the `/config` command, such as the IDs of designated categories and channels, game creation modes, role settings, and custom templates. This is necessary to make the bot function according to your server's rules.

* **User Information:**
    * **User ID:** We store the unique Discord User IDs of Game Masters (GMs) and players (if your server is configured to manage players individually). This is essential for applying correct permissions and for commands that manage game rosters.

* **Game Information:**
    * **Game Data:** We store information about games created through the bot, including their names, statuses (e.g., active, archived), and the IDs of their associated channels and roles.
    * **External Game Links:** If you use the `/game link_external` command, we store the association between a Galactic Campaigns game and the ID of that game in an external service (like RPG Sage).

* **Application Logs:**
    * For the purpose of debugging and maintaining the stability of the bot, we maintain application logs. These logs may include User IDs, Server IDs, and the commands used, particularly when an error occurs. These logs are stored securely and are only accessed for troubleshooting purposes.

---
### **2. How We Use Your Information**

The data we collect is used exclusively to provide and improve the Galactic Campaigns service. We use your data to:

* **Provide Core Functionality:** To create channels and roles, apply permissions, and manage the lifecycle of your games according to your server's configuration.
* **Enforce Permissions:** To verify that a user has the correct permissions to run a command (e.g., checking if a user is a GM of a specific game).
* **Provide Support:** To troubleshoot bugs and resolve issues that you report. User and Server IDs in our logs are critical for diagnosing problems.
* **Maintain and Improve the Service:** To monitor the bot's performance, identify and fix crashes, and make improvements to the user experience.

We will **never** sell your data or share it with third parties for marketing purposes.

---
### **3. Data Storage and Security**

All of Galactic Campaigns's data is stored in a secure SQLite database on a private, access-controlled server. We take reasonable measures to protect the information we store from loss, theft, misuse, and unauthorized access.

---
### **4. Data Retention and Deletion**

* **Server Data:** When Galactic Campaigns is kicked from your server, all associated data (server configurations, game data, permission profiles, etc.) is permanently deleted from our database.
* **User Data:** Your User ID is only stored in association with the games you are a GM or player in. If you are no longer a GM or player in any game on any server with Galactic Campaigns, your User ID will no longer be actively stored.
* **Requesting Data Deletion:** If you would like to request the manual deletion of your personal data (your User ID) from our logs and database, please join our official support server and contact an administrator.

---
### **5. Third-Party Services**

Galactic Campaigns uses Discord's API to function. Your use of Galactic Campaigns is also subject to the [Discord Privacy Policy](https://discord.com/privacy). For premium features, we may use a third-party payment processor like Patreon, which has its own privacy policy.

---
### **6. Changes to This Policy**

We may update this Privacy Policy from time to time. We will notify you of any significant