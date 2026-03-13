---
layout: default
title: Archives
---

<style>
    .archive-list { margin-top: 30px; }

    .archive-item {
        transition: transform 0.2s ease, border-color 0.2s ease;
        margin-bottom: 15px;
        padding: 20px;
        background: var(--secondary-bg);
        border: 1px solid var(--gh-border);
        border-radius: 6px;
        position: relative;
    }

    .archive-item:hover {
        transform: translateX(8px);
        border-color: var(--accent-blue);
        background: rgba(97, 218, 251, 0.05);
    }

    .archive-header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        flex-wrap: wrap;
        gap: 10px;
        margin-bottom: 8px;
    }

    .archive-link {
        font-size: 1.2rem;
        font-weight: bold;
        color: var(--accent-blue);
        letter-spacing: 0.5px;
        text-decoration: none;
        text-transform: uppercase;
    }

    .archive-meta {
        font-family: monospace;
        font-size: 0.85rem;
        color: var(--text-muted);
    }

    .archive-preview {
        font-size: 0.9rem;
        color: var(--gh-text);
        opacity: 0.8;
        line-height: 1.4;
        display: block;
        margin-top: 10px;
        border-top: 1px solid rgba(255, 255, 255, 0.1);
        padding-top: 10px;
        font-style: italic;
    }

    .signal-tag { color: var(--sw-yellow); font-weight: bold; }
    
    .status-badge {
        font-size: 0.6rem;
        padding: 2px 6px;
        border-radius: 3px;
        text-transform: uppercase;
        margin-left: 10px;
        vertical-align: middle;
    }
    .status-active { background: #238636; color: white; }
    .status-dropped { background: #da3633; color: white; }
</style>

<div class="archive-container">
    <h1 id="archive-title" style="color: var(--accent-blue); border-bottom: 2px solid var(--accent-blue); padding-bottom: 10px;">
        📡 Chapter Archives
    </h1>
    <p id="archive-status" style="font-style: italic; color: var(--text-muted);">
        Accessing encrypted campaign logs from the holonet...
    </p>

    <div id="archive-list-target" class="archive-list">
        <div class="archive-item">
            <p class="timestamp">Initializing secure uplink...</p>
        </div>
    </div>
</div>

<script>
document.addEventListener("DOMContentLoaded", async function() {
    const target = document.getElementById('archive-list-target');
    const titleEl = document.getElementById('archive-title');
    const statusEl = document.getElementById('archive-status');
    
    const params = new URLSearchParams(window.location.search);
    const slug = params.get('c');

    if (!slug) {
        target.innerHTML = `
            <div class="archive-item" style="border-style: dashed; text-align: center; padding: 40px;">
                <p style="color: var(--sw-yellow);"><strong>NO FREQUENCY SELECTED</strong></p>
                <p>Please select a campaign from the selector above to view its specific archives.</p>
            </div>`;
        statusEl.textContent = "Standby for input...";
        return;
    }

    try {
        const response = await fetch("{{ '/assets/galactic-registry.json' | relative_url }}?t=" + Date.now());
        if (!response.ok) throw new Error("Registry offline.");
        
        const registry = await response.json();
        const campaign = registry.campaigns[slug];

        if (!campaign) throw new Error("Invalid Campaign ID.");

        titleEl.textContent = `📡 ${campaign.name} Archives`;
        statusEl.textContent = `Displaying all transmissions for ${slug}...`;

        // Sort by Chapter Order (Descending)
        const sorted = campaign.logs.sort((a, b) => b.order - a.order);
        
        target.innerHTML = ""; // Clear loader

        sorted.forEach(log => {
            const dateStr = log.lastMessageTimestamp ? new Date(log.lastMessageTimestamp).toLocaleDateString(undefined, {
                year: 'numeric', month: 'long', day: 'numeric'
            }) : 'Unknown';

            // Determine viewer path based on file extension
            const viewerBase = log.fileName.endsWith('.json') ? "{{ '/logs' | relative_url }}" : "{{ '/entry' | relative_url }}";
            
            const item = document.createElement('div');
            item.className = "archive-item";
            
            // Highlight Dropped IDs (Phase 1 logic)
            const statusBadge = log.isActive === false 
                ? '<span class="status-badge status-dropped">DROPPED</span>' 
                : '<span class="status-badge status-active">ACTIVE</span>';

            item.innerHTML = `
                <div class="archive-header">
                    <a href="${viewerBase}?c=${slug}#${log.channelID}" class="archive-link">
                        ${log.title} ${statusBadge}
                    </a>
                    <div class="archive-meta">TRANSMITTED: ${dateStr}</div>
                </div>
                <div class="archive-meta">
                    SIGNAL STRENGTH: <span class="signal-tag">${log.messageCount} POSTS</span> | 
                    FILE: <code>${log.fileName}</code>
                </div>
                ${log.preview ? `<div class="archive-preview">${log.preview}</div>` : ''}
            `;
            target.appendChild(item);
        });

    } catch (e) {
        console.error("Archive Load Error:", e);
        target.innerHTML = `
            <div class="archive-item" style="border-color: #da3633;">
                <p style="color: #da3633;"><strong>DATABASE ERROR:</strong> ${e.message}</p>
            </div>`;
    }
});
</script>