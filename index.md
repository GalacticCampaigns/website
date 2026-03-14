---
layout: default
title: Home
---

<style>
/* 1. DASHBOARD LAYOUT */
.dashboard-grid {
    display: grid;
    grid-template-columns: 1fr 300px;
    gap: 30px;
    margin-top: 40px;
}

/* 2. LOG LIST STYLING */
.log-list {
    list-style: none;
    padding: 0;
}

.log-list li {
    padding: 15px 10px;
    border-bottom: 1px solid var(--gh-border);
    transition: 0.2s;
    border-radius: 4px;
}

.log-list li:hover {
    background: rgba(97, 218, 251, 0.05);
}

.log-list a {
    text-decoration: none;
    display: block;
}

/* 3. INFO ROW STYLING */
.log-info {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    flex-wrap: wrap;
    gap: 10px;
}

.chapter-title {
    font-weight: bold;
    color: var(--accent-blue);
    font-size: 1.1rem;
    text-transform: uppercase;
}

.campaign-tag {
    font-size: 0.7rem;
    background: rgba(97, 218, 251, 0.1);
    color: var(--accent-blue);
    padding: 2px 6px;
    border-radius: 3px;
    text-transform: uppercase;
    margin-right: 8px;
}

.signal-meta {
    margin: 5px 0;
    font-family: monospace;
    font-size: 0.75rem;
    color: var(--sw-yellow);
    letter-spacing: 1px;
}

.preview-text {
    margin-top: 5px;
    opacity: 0.7;
    font-style: italic;
    font-size: 0.9rem;
    color: var(--gh-text);
}

.hub-welcome {
    text-align: center;
    padding: 40px 20px;
    border: 1px dashed var(--gh-border);
    border-radius: 8px;
    margin-bottom: 20px;
}

/* 4. RESPONSIVE */
@media (max-width: 800px) {
    .dashboard-grid { grid-template-columns: 1fr; }
}
</style>

<div id="hub-view" class="hub-welcome" style="display: none;">
    <h2 style="color: var(--accent-blue);">Welcome to the Galactic Registry</h2>
    <p>Select an encrypted campaign frequency from the datapad above to begin decryption.</p>
</div>

<div class="dashboard-grid"> 
    <section class="update-panel">
        <h3 style="color: var(--accent-blue); border-bottom: 2px solid var(--accent-blue); padding-bottom: 10px;">
            <span class="icon">📡</span> <span id="feed-title">Recent Transmissions</span>
        </h3>
        <ul class="log-list" id="recent-logs-list">
            <li class="timestamp">Initializing holonet connection...</li>
        </ul>
        <a href="#" id="view-all-link" class="toc-open-btn" style="margin-top: 20px; text-decoration: none; width: 100%; justify-content: center; display: none;">View Full Archive →</a> 
    </section>

    <section class="wiki-panel" id="wiki-panel" style="display: none;">
        <h3 style="color: var(--sw-yellow);">
            <span class="icon">🗂️</span> Datapad Wiki
        </h3>
        <p id="wiki-desc" class="subtext">Access encrypted database for character profiles and technical specs.</p>
        <a href="#" id="wiki-cta" target="_blank" class="toc-open-btn" style="margin-top: 15px; width: 100%; justify-content: center; border-color: var(--sw-yellow) !important; color: var(--sw-yellow) !important;">Open Wiki</a>
    </section> 
</div>

<script>
document.addEventListener("DOMContentLoaded", async function() {
    const listContainer = document.getElementById('recent-logs-list');
    const hubView = document.getElementById('hub-view');
    const feedTitle = document.getElementById('feed-title');
    const viewAllLink = document.getElementById('view-all-link');
    const wikiPanel = document.getElementById('wiki-panel');

    const params = new URLSearchParams(window.location.search);
    const slug = params.get('c');

    try {
        const res = await fetch("{{ '/assets/campaign-registry.json' | relative_url }}");
        const registry = await res.json();
        let displayLogs = [];

        if (slug && registry.campaigns[slug]) {
            // --- CAMPAIGN SPECIFIC VIEW ---
            const campaign = registry.campaigns[slug];
            feedTitle.innerText = `${campaign.name}: Recent Transmissions`;
            viewAllLink.href = `{{ '/archives' | relative_url }}?c=${slug}`;
            viewAllLink.style.display = 'flex';

            if (campaign.paths && campaign.paths.wiki) {
                wikiPanel.style.display = 'block';
                document.getElementById('wiki-cta').href = campaign.paths.wiki;
            }

            // Filter active logs, sort by lastMessageTimestamp, take top 3
            displayLogs = campaign.logs
                .filter(l => l.isActive !== false)
                .sort((a, b) => new Date(b.lastMessageTimestamp) - new Date(a.lastMessageTimestamp))
                .slice(0, 3)
                .map(l => ({ ...l, campaignSlug: slug, campaignName: campaign.name }));

        } else {
            // --- GLOBAL FEED VIEW ---
            hubView.style.display = 'block';
            feedTitle.innerText = "Latest Global Signals";
            
            // Flatten all logs from all campaigns
            let allLogs = [];
            Object.keys(registry.campaigns).forEach(cSlug => {
                const camp = registry.campaigns[cSlug];
                const logsWithMeta = camp.logs
                    .filter(l => l.isActive !== false)
                    .map(l => ({ 
                        ...l, 
                        campaignSlug: cSlug, 
                        campaignName: camp.name 
                    }));
                allLogs = allLogs.concat(logsWithMeta);
            });

            // Sort all logs by timestamp, take top 5
            displayLogs = allLogs
                .sort((a, b) => new Date(b.lastMessageTimestamp) - new Date(a.lastMessageTimestamp))
                .slice(0, 5);
        }

        if (displayLogs.length === 0) {
            listContainer.innerHTML = "<li>No active transmissions found.</li>";
            return;
        }

        listContainer.innerHTML = ""; 
        displayLogs.forEach(log => {
            const li = document.createElement('li');
            const viewerPath = log.fileName.endsWith('.json') ? "{{ '/logs' | relative_url }}" : "{{ '/entry' | relative_url }}";
            
            // Format timestamp for display
            const dateObj = new Date(log.lastMessageTimestamp);
            const dateStr = isNaN(dateObj) ? "" : dateObj.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });

            li.innerHTML = `
                <a href="${viewerPath}?c=${log.campaignSlug}#${log.channelID}">
                    <div class="log-info">
                        <div>
                            ${!slug ? `<span class="campaign-tag">${log.campaignName}</span>` : ''}
                            <span class="chapter-title">${log.title}</span>
                        </div>
                        <span class="timestamp" style="font-family: monospace; font-size: 0.8rem; color: var(--text-muted);">${dateStr}</span>
                    </div>
                    <p class="preview-text">${log.preview || 'Narrative stream active...'}</p>
                </a>
            `;
            listContainer.appendChild(li);
        });

    } catch (e) {
        console.error("Dashboard Error:", e);
        listContainer.innerHTML = "<li><span style='color:var(--sw-yellow);'>📡 UPLINK ERROR:</span> Failed to retrieve transmissions.</li>";
    }
});
</script>
