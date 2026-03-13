---
layout: default
title: Chapter Archives
---

# 📡 Chapter Archives

*Accessing encrypted campaign logs from the holonet...*

<div id="archive-list-target" class="archive-list">
    <div class="panel archive-item">
        <p class="timestamp">Initializing secure uplink...</p>
    </div>
</div>

<style>
    .archive-list {
        margin-top: 30px;
    }

    .archive-item {
        transition: transform 0.2s ease, border-color 0.2s ease;
        margin-bottom: 15px;
        padding: 20px;
        background: var(--panel-bg);
        border: 1px solid var(--gh-border);
        border-radius: 6px;
    }

    .archive-item:hover {
        transform: translateX(8px);
        border-color: var(--sw-blue);
        background: rgba(88, 166, 255, 0.05);
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
        color: var(--sw-blue);
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
        border-top: 1px solid rgba(255, 255, 255, 0.05);
        padding-top: 10px;
        font-style: italic;
    }

    .signal-tag {
        color: var(--sw-yellow);
        font-weight: bold;
    }
</style>

<script>
document.addEventListener("DOMContentLoaded", async function() {
    const target = document.getElementById('archive-list-target');
    
    try {
        // Fetch the manifest with a cache-buster
        const response = await fetch("{{ '/assets/log-manifest.json' | relative_url }}?t=" + new Date().getTime());
        if (!response.ok) throw new Error("Manifest sequence offline.");
        
        const manifest = await response.json();

        // Sort by Chapter Order (Descending - Newest Chapter at the top)
        const sorted = manifest.sort((a, b) => b.order - a.order);
        
        target.innerHTML = ""; // Clear loader

        sorted.forEach(log => {
            const date = new Date(log.lastMessageTimestamp).toLocaleDateString(undefined, {
                year: 'numeric',
                month: 'long',
                day: 'numeric'
            });

            const item = document.createElement('div');
            item.className = "panel archive-item";
            item.innerHTML = `
                <div class="archive-header">
                    <a href="{{ '/logs' | relative_url }}#${log.channelID}" class="archive-link">
                        ${log.title}
                    </a>
                    <div class="archive-meta">
                        TRANSMITTED: ${date}
                    </div>
                </div>
                <div class="archive-meta">
                    SIGNAL STRENGTH: <span class="signal-tag">${log.messageCount} POSTS DETECTED</span> | FREQUENCY: ${log.channelID}
                </div>
                ${log.preview ? `<div class="archive-preview">${log.preview}</div>` : ''}
            `;
            target.appendChild(item);
        });

    } catch (e) {
        console.error("Archive Load Error:", e);
        target.innerHTML = `
            <div class="panel archive-item" style="border-color: var(--sw-red, red);">
                <p style="color: var(--sw-red, red);"><strong>DATABASE ERROR:</strong> Failed to retrieve log manifest.</p>
            </div>`;
    }
});
</script>
