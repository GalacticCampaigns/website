## 🛠️ Project Objective
To transform a hierarchical, server-side dependent forum database into a high-performance, mobile-optimized, static JSON-driven archive that maintains the original "thread" feel and nested category navigation.

---

## 🏛️ Phase 1: The "Extraction Factory" (Raspberry Pi)
Since GitHub Pages cannot "talk" to your MySQL server, your Pi acts as the **Build Server**. It processes the heavy data and pushes "flat" files to the repository.

### 1.1 Source Mapping (phpBB3 Schema)
You must join specific tables to reconstruct the narrative.
| Entity | phpBB3 Table | Purpose |
| :--- | :--- | :--- |
| **Hierarchy** | `phpbb_forums` | Contains $left\_id$ and $right\_id$ for nesting. |
| **Threads** | `phpbb_topics` | The metadata for each conversation (Title, Views, Author). |
| **Narrative** | `phpbb_posts` | The actual dialogue and timestamps. |
| **Identities** | `phpbb_users` | To map legacy usernames to modern avatars. |

### 1.2 The Transformation Script (Python/Node)
You will write a script (the "Legacy Hydrator") that performs these three tasks:
1.  **Recurse the Tree:** Walk the `phpbb_forums` table using the Nested Set Model to build `legacy-map.json`.
2.  **Generate Leaf Files:** For every `topic_id`, create a standalone `topic_{id}.json` file.
3.  **Sanitize Content:** Regex-convert BBCode (`[b]`) to Markdown (`**`) and strip forum signatures.

---

## 📂 Phase 2: Data Templates & Formatting

### 2.1 The Recursive Manifest (`legacy-map.json`)
This is the "Brain" of the navigation. It tells the browser what folders exist without loading every post.

```json
{
  "version": "1.0-Legacy",
  "root": [
    {
      "id": 1,
      "name": "THE OLD REPUBLIC",
      "type": "category",
      "children": [
        {
          "id": 42,
          "name": "Coruscant Underworld",
          "type": "forum",
          "topicCount": 156,
          "topics": [
            { "id": 1002, "title": "The Heist on Level 1313", "author": "Alicia", "date": "2015-04-12" }
          ]
        }
      ]
    }
  ]
}
```

### 2.2 The Topic Payload (`topic_1002.json`)
This replaces the current "Chapter" JSON. It includes metadata for the "Forum" look.

```json
{
  "topicId": 1002,
  "title": "The Heist on Level 1313",
  "posts": [
    {
      "postId": 5542,
      "author": { "name": "Alicia", "rank": "Game Master", "id": 4 },
      "timestamp": "2015-04-12T14:20:00Z",
      "content": "The shadows of **Level 1313** grew long as the freighter touched down...",
      "attachments": []
    }
  ]
}
```

---

## 🛸 Phase 3: The "Explorer" UI (Frontend)

### 3.1 The Navigation Logic
You will create a new `legacy-viewer.js` that functions as a **State Machine**:
* **State: ROOT** → Render Category Cards.
* **State: FORUM** → Render Topic Tables.
* **State: TOPIC** → Render Post Stream (similar to current `log.js`).

### 3.2 Mobile-First Breadcrumbs (S25 Ultra Optimized)
To prevent overflow, the breadcrumb will use a **"Parent-Truncation"** strategy.
> **Logic:** If `path.length > 2`, hide middle segments under a `...` dropdown. Only show the current location and the immediate parent.

---

## ⚡ Challenges & Strategic Solutions

### Challenge 1: The "BBCode to Markdown" Translation
* **Problem:** Forum posts are littered with `[quote="User"]` and `[img]`. Your Discord parser won't understand these.
* **Solution:** Use a "Translation Pipeline" in your Python script.
    * `[b]` → `**`
    * `[quote=(.*?)]` → `> **$1 said:** \n > `
    * `[color=#.*?](.*?)[\/color]` → `$1` (Strip colors to maintain site theme).

### Challenge 2: Massive File Counts
* **Problem:** Pushing 5,000 small JSON files can slow down GitHub Actions and Git operations.
* **Solution:** **Bucketization.** Group topics into subfolders by Forum ID: `assets/legacy/12/topic_1002.json`. This keeps directory indexing fast.

### Challenge 3: Identity Fragmentation
* **Problem:** Users from 2015 have different names/avatars than 2026 Discord users.
* **Solution:** **The Master Identity Map.** Create a `user-bridge.json` that the viewer uses to "hot-swap" legacy forum IDs with modern Discord avatars, creating a unified narrative feel across both eras.

### Challenge 4: Internal Link Rot
* **Problem:** Old posts link to `viewtopic.php?t=123`. These links will return 404s.
* **Solution:** **The "Legacy Interceptor."** Add a global listener in `navigation.js` that catches any clicks on URLs containing `viewtopic.php`. It parses the ID and reroutes the user to your new static URL: `logs-legacy?t=123`.

---

## 🚀 Execution Checklist
1.  [ ] **Tunnel Test:** Verify the Pi can stream a query via Cloudflare to your local Python environment.
2.  [ ] **Schema Audit:** Identify all `forum_id` values that are "In-Character" (to ignore Out-of-Character chatter).
3.  [ ] **JSON Export:** Run the first pass of the "Hydrator" script to generate the `legacy-map.json`.
4.  [ ] **The "Imperial Archive" CSS:** Create a CSS file that applies a unique "Historical" theme to these specific pages.