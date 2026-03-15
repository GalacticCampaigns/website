# Project Holonet: Standard Operating Procedure (SOP) & Development Plan

Version: 1.5.0 (Final Architecture Edition)

## Status: Active Development / Maintenance Mode
1. Project Overview
The "Project Holonet" Log System is an immersive, web-based archive designed to display Discord-based roleplay sessions for the Star Wars: Forgotten Ones campaign. It mimics a high-tech "In-Universe Datapad," utilizing a serverless architecture where raw Discord JSON data is transformed into a navigable, interactive interface through client-side JavaScript and automated PowerShell processing.
2. System Architecture & Data Flow
The Pipeline
 * Export: Raw Discord data is exported via Discrub (or automated CLI tools).
 * Storage: JSON files are stored in /Chapter_Logs/JSON/.
 * Automation (Manifest Generator): A GitHub Action triggers manifest-gen.ps1. This generates log-manifest.json, the "back-end" database.
 * Routing (Enhanced): The viewer utilizes Thread-Aware Hash Routing (/logs#ID:msgID). The system identifies if the ID is a Chapter or a Thread and resolves the parent file automatically.
 * Render: The json-viewer.html logic builds the feed, handles auto-image embedding, and manages the breadcrumb state.
3. Development Standards (CSS & Layout)
The Datapad utilizes a "Sticky Stacking" system to manage complex navigation layers.
A. Universal Styling (/assets/style.css)
 * Tier 1: .site-nav (Global Navigation) — top: 0px (50px height).
 * Tier 2: .frozen-nav (Breadcrumb Console) — top: 50px (60px height). Includes the "Secret Menu" for chapter switching.
 * Tier 3: .frequency-nav-bar (Thread Switcher) — top: 110px. Activated by the 📡 icon.
 * Sticky Requirements: Every parent container, including the <main> tag, must be set to overflow: visible !important.
B. Mobile Optimization [COMPLETED]
 * Portrait Fixes: Media queries flatten heights and adjust avatar sizes.
 * Touch Targets: Dropdowns and frequency buttons are sized for thumb-navigation.
 * Breadcrumb Truncation: Long thread names are truncated with ellipsis to prevent UI overflow on narrow screens.
4. Automation: The Smart Manifest (manifest-gen.ps1)
The manifest uses the Discord Channel ID as the unique primary key. This allows file renaming without breaking deep links.
**Metadata Definitions**
 * channelID: Unique Discord Snowflake ID.
 * messageCount: Total posts (excluding system messages).
 * lastMessageTimestamp: Used for chronological sorting.
 * Persistence Logic: The script preserves manual edits to title and preview while updating technical counts.
5. The "Smart" JSON Viewer Logic
Breadcrumb & Navigation [NEW]
 * The Secret Menu: The chapter title in the breadcrumb acts as a trigger for a custom dropdown, replacing the standard HTML <select> for a more immersive look.
 * Frequency Detection: A "Pre-Scan" maps thread_ids to names and identifies sub-channels.
 * Deep-Link Resolution: The init() function performs a deep-search across all chapters and threads to find the correct file for any shared ID.
Extended Markdown Support
 * Headers: Standard # through ###### support.
 * Subtext: -# support for small, muted text.
 * Auto-Embed: Naked image URLs (specifically Wikia/Fanon URLs) are detected and converted into visual image attachments automatically.
 * Block Elements: Support for blockquotes (>) and multi-line code blocks (triple backticks).
6. Maintenance SOP
Adding Chapters
 * Upload JSON to /Chapter_Logs/JSON/.
 * The manifest-gen script will detect it. Ensure the first message contains a Markdown header for auto-titling.
 * Manual Overrides: Edit assets/log-manifest.json to change titles or narrative previews.
7. Future Implementation Roadmap
Phase 1: Mobile UI Stabilization [COMPLETED]
 * Goal: Ensure sticky bars work on all mobile aspect ratios.
 * Outcome: Fixed via relative positioning and portrait-specific CSS overrides.
Phase 2: Deep-Link & Shared URL Logic [COMPLETED]
 * Goal: Allow sharing of specific threads or messages.
 * Outcome: Implemented via the init() deep-search and composite hash resolution.
Phase 3: Automated Discord Backup (The Daily Dump)
 * Goal: Move away from manual Discrub exports.
 * Method: Deploy a GitHub Action using DiscordChatExporter.Cli. Run on a 24-hour schedule to commit JSON files directly to the repository.
Phase 4: Media Gallery & Lightbox
 * Goal: Provide a dedicated view for in-game art and maps.
 * Method: Create a "Media" tab in the Frequency Bar that filters the JSON for attachments and naked URLs, displaying them in a CSS grid.
Phase 5: Wiki Bridge Integration
 * Goal: Use existing Wiki summaries as "Mission Briefings."
 * Method: Pull content from the GitHub Wiki repo and render it as an "Encrypted Briefing" at the top of relevant chapters.

Version: 1.5.0
