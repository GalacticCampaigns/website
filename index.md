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
    padding: 60px 20px;
    border: 1px dashed var(--gh-border);
    border-radius: 8px;
}

/* 4. RESPONSIVE */
@media (max-width: 800px) {
    .dashboard-grid { grid-template-columns: 1fr; }
}
</style>

<div id="hub-view" class="hub-welcome">
    <h2 style="color: var(--accent-blue);">Welcome to the Galactic Registry</h2>
    <p>Select an encrypted campaign frequency from the datapad above to begin decryption and access mission logs.</p>
</div>

<div id="campaign-view" class="dashboard-grid" style="display: none;"> 
    <section class="update-panel">
        <h3 style="color: var(--accent-blue); border-bottom: 2px solid var(--accent-blue); padding-bottom: 10px;">
            <span class="icon">📡</span> Recent Transmissions
        </h3>
        <ul class="log-list" id="recent-logs-list">
            <li class="timestamp">Initializing holonet connection...</li>
        </ul>
        <a href="#" id="view-all-link" class="toc-open-btn" style="margin-top: 20px; text-decoration: none; width: 100%; justify-content: center;">View Full Archive →</a> 
    </section>

    <section class="wiki-panel">
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
    const campaignView = document.getElementById('campaign-view');
    
    // 1. Resolve Slug
    const params = new URLSearchParams(window.location.search);
    const slug = params.get('c');

    if (!slug) {
        hubView.style.display = 'block';
        campaignView.style.display = 'none';
        return;
    }

    try {
        const res = await fetch("{{ '/assets/campaign-registry.json' | relative_url }}");
        const registry = await res.json();
        const campaign = registry.campaigns[slug];

        if (!campaign) throw new Error("Frequency Unknown");

        // UI Prep
        hubView.style.display = 'none';
        campaignView.style.display = 'grid';
        document.getElementById('view-all-link').href = `{{ '/archives' | relative_url }}?c=${slug}`;
        
        // Wiki Logic
        if (campaign.paths && campaign.paths.wiki) {
            document.getElementById('wiki-cta').href = campaign.paths.wiki;
        } else {
            document.querySelector('.wiki-panel').style.display = 'none';
        }

        // 2. Fetch recent logs for this specific campaign
        // Using the campaign's specific log array from the registry
        listContainer.innerHTML = ""; 

        // Get the last 3 logs from the campaign's manifest/registry entry
        const recentLogs = campaign.logs.slice(-3).reverse();

        recentLogs.forEach(log => {
            const li = document.createElement('li');
            // Check if log is JSON or Markdown to determine the link path
            const viewerPath = log.fileName.endsWith('.json') ? "{{ '/logs' | relative_url }}" : "{{ '/entry' | relative_url }}";
            
            li.innerHTML = `
                <a href="${viewerPath}?c=${slug}#${log.channelID}">
                    <div class="log-info">
                        <span class="chapter-title">${log.title}</span>
                        <span class="timestamp" style="font-family: monospace; font-size: 0.8rem; color: var(--text-muted);">${log.date || ''}</span>
                    </div>
                    <p class="signal-meta">
                        ORIGIN: ${log.fileName}
                    </p>
                    <p class="preview-text">${log.preview || 'Narrative stream active...'}</p>
                </a>
            `;
            listContainer.appendChild(li);
        });

    } catch (e) {
        console.error("Dashboard Error:", e);
        listContainer.innerHTML = "<li><span style='color:var(--sw-yellow);'>📡 UPLINK ERROR:</span> Failed to retrieve recent transmissions for this frequency.</li>";
    }
});
</script>