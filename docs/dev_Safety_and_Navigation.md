# 🛸 System Architecture: Safety & Navigation

**Version:** 1.0

**Status:** Development Phase

**Core Objective:** Implement a consent-based NSFW filtering system and a high-utility navigation interface for long-form narrative logs.

---

## I. Global State & Persistence

To ensure user preferences are respected across the entire site without a backend, the system utilizes `localStorage` and a centralized state object.

### 1. State Variables (`window.GC_STATE`)

Added properties to the existing navigation state:

* `nsfwEnabled` (Boolean): The current user preference.
* `mediaRegistry` (Map): A lookup table of file-level metadata (NSFW status, content warnings).
* `lastPosition` (Number): The Y-coordinate of the user's scroll before a "Jump to Bottom" was triggered.

### 2. Persistence Logic

* **Initialization:** On load, `navigation.js` checks `localStorage.getItem('GC_NSFW_ENABLED')`.
* **Default Policy:** Secure-by-default (NSFW = False).
* **Session Continuity:** Scroll positions are tracked per-campaign slug to ensure that switching chapters doesn't trigger erratic jump-back behavior.

---

## II. NSFW Compliance Strategy

The system handles mature content at three distinct levels of granularity.

### 1. Campaign & Log Level (Registry)

* **Logic:** If `isNSFW: true` is found in `campaign-registry.json` for a campaign or a specific log entry.
* **UI Impact:**
* **Hub/Archives:** Previews are blurred via CSS. A `[MATURE]` badge is appended to the title.
* **Dropdown:** An icon (🔞) indicates restricted frequencies.
* **Redirect:** Direct deep-links to NSFW content while the filter is **ON** trigger a "Gatekeeper" confirmation overlay.



### 2. Media Level (Sidecar JSON)

Each campaign repository contains a `media-registry.json`.

* **The Look-up Table:** Contains a list of filenames/paths marked as NSFW.
* **The Shield:** If a file is in the list and the user is in SFW mode, the viewer renders a "Restricted Data" block instead of the image.
* **Zero-Leak Fetching:** The browser `src` attribute is not populated for restricted images until consent is provided, preventing background caching of mature content.

### 3. CSS "Redaction" System

We use a "Terminal-style" aesthetic for filtered content:

* **`.nsfw-blur`:** Applied to text previews (Gaussian blur + unselectable text).
* **`.nsfw-shield`:** A patterned overlay for images with a "Decrypt Media" button.
* **Global Class:** The `<body>` tag receives a `.mode-nsfw` or `.mode-sfw` class, allowing CSS variables to change the site’s "Alert Level" (e.g., changing accent colors from Blue to Amber).

---

## III. Advanced Navigation HUD

For long-form logs, we move beyond basic scrolling to a "Comms-style" navigation interface.

### 1. Floating Action HUD (Bottom-Right)

A sticky group of buttons providing instant movement:

* **🔽 Jump to Bottom:** Instantly scrolls to the most recent transmission.
* **🔼 Jump to Top:** Standard return to header.
* **↪️ Return to Position:** This button appears dynamically. It remembers where the user was before they jumped to the bottom, allowing them to "snap back" to where they were reading.

### 2. The Footer Control Bar

The site footer acts as the "Settings Dashboard":

* **NSFW Toggle:** A manual switch to enable/disable the global filter.
* **Visual Status:** Displays `FILTER: ACTIVE` (Green) or `FILTER: DISABLED` (Red/Amber).

---

## IV. Technical Implementation Roadmap

### Step 1: Registry Updates

Update `campaign-registry.json` to include `isNSFW` flags where appropriate. Campaign owners must add `media-registry.json` to their asset folders.

### Step 2: Navigation.js Expansion

* Implement `updateNSFWMode(boolean)` function.
* Implement `saveScrollPosition()` and `restoreScrollPosition()` logic.
* Add event listeners for the `GC_NSFW_Updated` custom event to allow real-time UI updates without page refreshes.

### Step 3: Layout Integration (`_layouts/default.html`)

* Inject the **Floating HUD** HTML.
* Inject the **NSFW Toggle** into the footer.
* Add the **Gatekeeper Modal** (Hidden by default).

### Step 4: Viewer Refactor (`json-viewer.html`)

* Modify `renderAttachments` to check against the `mediaRegistry`.
* Modify `renderFeed` to check for thread-level NSFW flags.

---

## V. Detailed User Experience Flow

1. **Entry:** User arrives at the Hub. All NSFW campaigns are blurred/hidden.
2. **Toggle:** User goes to the footer and toggles "Clearance Level."
3. **Confirmation:** A modal appears: *"Confirm age/content warning."*
4. **Decrypt:** Upon confirmation, `localStorage` updates, and all blurs across the site vanish instantly.
5. **Reading:** User opens a long log, reads halfway, then clicks "Jump to Bottom" to see the latest post.
6. **Return:** User clicks the "Return" arrow in the HUD to immediately snap back to their exact previous reading spot.

---

### Record Summary for Developer

* **Primary Filter:** CSS Class-based (`.nsfw-masked`).
* **Source of Truth:** `window.GC_STATE`.
* **Storage:** `localStorage`.
* **Navigation:** Coordinate-based memory (Scroll-X/Y).

---

## Apendix A: **Media-Level NSFW Shielding**:

### 1. The Data Structure (`media-registry.json`)

Each campaign repository will include an optional `media-registry.json` in its `dataPath`. This file will serve as a look-up table for the website's rendering engine.

**Proposed Schema:**

```json
{
  "nsfw_files": [
    "folder_name/image1.png",
    "folder_name/image2.jpg"
  ],
  "content_warnings": {
    "folder_name/image3.png": "Violence",
    "folder_name/document.pdf": "Flashy Lights"
  }
}

```

### 2. Integration with `navigation.js`

We need to update the global state to handle this secondary fetch.

* **Parallel Fetch:** When a campaign is loaded, `navigation.js` should check if a `media-registry.json` exists in that campaign's remote path.
* **Global Media Map:** Store the result in `window.GC_STATE.mediaMetadata`.
* **Fallback:** If the file doesn't exist (404), the system assumes all media is SFW by default (graceful degradation).

### 3. The "Smart Loader" Logic

The `renderAttachments` function in your viewer needs to be upgraded to a "Safe Loader."

* **The Interceptor:** Before creating the `<img>` or `<a>` tag, the script checks:
* *Is this filename in the `nsfw_files` list?*
* *Is the user's Global NSFW flag set to OFF?*


* **Conditional Rendering:**
* **If Restricted:** Instead of an `<img>` tag, it renders a "Static Shield" (a div with a warning icon and a "Click to View" overlay).
* **If Approved:** It renders the standard `<img>` tag.


* **The "No-Leaking" Rule:** The `src` attribute of the actual image should **not** be set until the user clicks the shield. This prevents the browser from pre-fetching/caching sensitive images in the background.

### 4. CSS-Based Concealment

To make the UX feel high-tech (fitting the "Galactic" theme), we can use a "Corrupted Data" aesthetic for hidden media.

* **The Mask:** A CSS class that uses a heavy blur and a repeating "RESTRICTED ACCESS" background pattern.
* **The Reveal:** A smooth transition from the blur to the clear image once the user confirms they want to see that specific piece of media.

---

## Apendix B: **Persistent Jump Navigation**:

### 1. The "Anchor Memory" Logic

We need a way to track the "Last Known Position" without cluttering the URL hash constantly.

* **Scroll Tracking:** A passive listener in `navigation.js` will monitor the scroll position. When the user stops scrolling for more than a second, it saves the current `window.scrollY` to a session variable.
* **The "Return" Trigger:** If the user clicks a "Jump to Bottom" button, the script stores the *pre-jump* coordinate as the "Memory Point."
* **Context Sensitivity:** This memory should be unique per campaign/log. If I’m on "Campaign A - Chapter 1," it shouldn't try to jump me to a random coordinate when I switch to "Campaign B."

---

### 2. Floating Navigation UI (The "Comms HUD")

Instead of just a footer link, we can implement a subtle, high-tech floating button group in the bottom-right corner.

* **Arrow Down (Jump to Bottom):** Quickly slides the user to the end of the log.
* **Arrow Up (Jump to Top):** Standard accessibility.
* **The "Return" Icon (Jump Back):** This button only appears *after* the user has used a jump command. It acts like a "Undo Scroll" feature.
* *Visual Style:* A circular arrow or a "Back" icon with a coordinate tooltip.

---

### 3. Integration with NSFW Toggle

Since you want the NSFW toggle in the footer, we should group these "System Controls" together for a consistent "Terminal" feel.

* **The Footer Control Bar:**
* Left side: NSFW Toggle (Security Clearance).
* Center: "Return to Top" link.
* Right side: Status indicators (Registry version, etc.).


* **Sticky HUD:** The Jump buttons remain floating over the content so they are always reachable, even in the middle of a 200-post log.

---

### 4. Implementation Roadmap

| Component | Logic | Goal |
| --- | --- | --- |
| **Global HUD** | Add a floating `div` to `default.html` containing the arrows. | Constant access to navigation. |
| **Scroll Memory** | Add `window.GC_STATE.lastPosition` to the global state. | Track where the user was before a jump. |
| **NSFW Footer Sync** | Style the footer to house the toggle and a "Top" shortcut. | Centralize system settings. |
| **Smooth Transitions** | Use `window.scrollTo({ behavior: 'smooth' })`. | Ensure the jump doesn't feel disorienting. |

---

### 5. Next Step: Layout Refactor

To get this working, we need to modify `_layouts/default.html` to include:

1. A CSS container for the **Floating HUD**.
2. A CSS container for the **Footer Control Bar** (including the NSFW toggle).
3. The updated `navigation.js` to handle the coordinate math.
