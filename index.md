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
    padding: 15px 0;
    border-bottom: 1px solid var(--gh-border);
    transition: 0.2s;
}

.log-list li:hover {
    background: rgba(88, 166, 255, 0.03);
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
    color: var(--sw-blue);
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

/* 4. RESPONSIVE */
@media (max-width: 800px) {
    .dashboard-grid { grid-template-columns: 1fr; }
}
</style>

<div class="dashboard-grid"> 
    <section class="update-panel">
        <h3><span class="icon">📡</span> Recent Chapter Logs</h3>
        <ul class="log-list" id="recent-logs-list">
            <li class="timestamp">Initializing holonet connection...</li>
        </ul>
        <a href="{{ '/archives' | relative_url }}" class="view-all">View Full Archive →</a> 
    </section>

    <section class="wiki-panel">
        <h3><span class="icon">🗂️</span> <a href="https://github.com/alicia86/SW_ForgottenOnes/wiki" class="wiki-card">Datapad Wiki</a></h3>
        <p class="subtext">Access encrypted database for character profiles and technical specs.</p>
    </section> 
</div>

<script>
document.addEventListener("DOMContentLoaded", async function() {
    const listContainer = document.getElementById('recent-logs-list');
    
    try {
        // Fetch fresh manifest with cache buster
        const response = await fetch("{{ '/assets/log-manifest.json' | relative_url }}?t=" + new Date().getTime());
        if (!response.ok) throw new Error("Connection failed");
        
        const manifest = await response.json();

        // Sort by lastMessageTimestamp (Newest activity first)
        const sorted = manifest.sort((a, b) => new Date(b.lastMessageTimestamp) - new Date(a.lastMessageTimestamp));
        
        listContainer.innerHTML = ""; // Clear loader message

        // Take the most recent transmissions
        sorted.slice(0, 1).forEach(log => {
            const date = new Date(log.lastMessageTimestamp).toLocaleDateString();
            const li = document.createElement('li');
            
            li.innerHTML = `
                <a href="{{ '/logs' | relative_url }}#${log.channelID}">
                    <div class="log-info">
                        <span class="chapter-title">${log.title}</span>
                        <span class="timestamp">${date}</span>
                    </div>
                    <p class="signal-meta">
                        SIGNAL STRENGTH: ${log.messageCount} POSTS DETECTED
                    </p>
                    <p class="preview-text">${log.preview || 'No narrative preview available.'}</p>
                </a>
            `;
            listContainer.appendChild(li);
        });

    } catch (e) {
        console.error("Dashboard Error:", e);
        listContainer.innerHTML = "<li><span style='color:red;'>📡 UPLINK ERROR:</span> Failed to retrieve recent transmissions.</li>";
    }
});
</script>
