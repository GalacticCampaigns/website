// assets/js/log.js

// --- 1. GLOBAL STATE ---
let fullData = [];
window.channelMap = {}; 
let mainChannelId = null;

// --- 2. INITIALIZATION ---
async function init() {
    try {
        if (!window.GC_STATE || !window.GC_STATE.isReady) {
            await updateGlobalNav(); 
        }

        registry = window.GC_STATE.registry;
        activeCampaign = window.GC_STATE.currentCampaign;
        campaignSlug = window.GC_STATE.campaignSlug;
        remoteBase = window.GC_STATE.remoteBase;

        const { slug, channelId, messageId } = getUrlContext();
        
        if (!activeCampaign) {
            throw new Error("No active campaign selected. Please return to the Hub.");
        }

        const backBtn = document.getElementById('back-to-archives');
        if (backBtn) {
            backBtn.href = `${window.site_baseurl}/archives?c=${campaignSlug}`;
        }

        const listTarget = document.getElementById('chapter-list-dropdown');
        if (listTarget) {
            listTarget.innerHTML = "";
            activeCampaign.logs.forEach(item => {
                const div = document.createElement('div');
                div.className = "chapter-option";
                div.textContent = item.title;
                div.onclick = (e) => {
                    e.stopPropagation();
                    toggleChapterList();
                    loadChapter(item.channelID);
                };
                listTarget.appendChild(div);
            });
        }

        const rawHash = window.location.hash.substring(1);
        let chanId = null;
        let msgId = null;
        let autoFilter = 'all';

        if (rawHash) {
            const hashParts = rawHash.split(':');
            const primaryId = hashParts[0];
            msgId = hashParts[1] || null;

            let targetChapter = activeCampaign.logs.find(l => l.channelID === primaryId);
            
            if (targetChapter) {
                chanId = primaryId;
                autoFilter = 'all';
            } else {
                const parentLog = activeCampaign.logs.find(l => 
                    l.threads && l.threads.some(t => t.threadID === primaryId)
                );
                
                if (parentLog) {
                    targetChapter = parentLog;
                    chanId = parentLog.channelID;
                    autoFilter = primaryId; 
                    if (!msgId) msgId = primaryId; 
                } else {
                    const crossRef = resolveInternalLinkData(primaryId);
                    if (crossRef.found && crossRef.slug !== campaignSlug) {
                        window.location.href = `${window.site_baseurl}/logs?c=${crossRef.slug}#${rawHash}`;
                        return;
                    }
                }
            }

            if (targetChapter) {
                await loadChapter(chanId, msgId, autoFilter);
                return;
            }
        }

        if (activeCampaign.logs.length > 0) {
            await loadChapter(activeCampaign.logs[0].channelID);
        } else {
            throw new Error("This campaign contains no log entries.");
        }

    } catch (e) {
        console.error("Init Error:", e);
        const output = document.getElementById('viewer-output');
        if (output) {
            output.innerHTML = `<div style="padding: 20px; border: 1px dashed var(--sw-yellow); text-align: center;"><b style="color:var(--sw-yellow)">SYSTEM ERROR:</b><br>${e.message}<br><br><a href="${window.site_baseurl}/" style="color: var(--text-muted)">Return to Hub</a></div>`;
        }
    }
}

// Listen for global NSFW toggle to re-render attachments
document.addEventListener('NSFWStateChanged', () => {
    if (!fullData || fullData.length === 0) return;
    const currentHash = window.location.hash.substring(1).split(':')[0] || 'all';
    renderFeed(currentHash);
});

// Update HUD visibility on scroll
window.addEventListener('scroll', () => {
    if (window.GC_STATE.hasJumped) {
        if (Math.abs(window.scrollY - window.GC_STATE.lastScrollPos) < 100) {
            window.GC_STATE.hasJumped = false;
            updateHUDVisibility();
        }
    }
});

// --- 3. DATA LOADING ---
async function loadChapter(channelID, targetMsg = null, autoFilter = null) {
    const logEntry = activeCampaign.logs.find(l => l.channelID === channelID);
    if (!logEntry) return;

    const jsonUrl = `${remoteBase}${activeCampaign.paths.json}${logEntry.fileName}`;
    const output = document.getElementById('viewer-output');
    output.innerHTML = "<em>Decrypting Data Stream...</em>";

    try {
        const response = await fetch(jsonUrl);
        const data = await response.json();
        fullData = Array.isArray(data) ? data : (data.messages || []);
        fullData.sort((a, b) => a.timestamp.localeCompare(b.timestamp));

        updateBreadcrumb(logEntry.title);

        window.channelMap = {}; 
        let parentCounts = {};
        fullData.forEach(m => {
            // Vault logic: Map channel_id names
            if (m.thread) {
                window.channelMap[m.thread.id] = m.thread.name.toUpperCase();
                if (m.thread.parent_id) parentCounts[m.thread.parent_id] = (parentCounts[m.thread.parent_id] || 0) + 1;
            }
        });

        mainChannelId = Object.keys(parentCounts).reduce((a, b) => parentCounts[a] > parentCounts[b] ? a : b, null) || channelID;
        window.GC_STATE.currentMainChannelId = mainChannelId;
        buildFrequencyBar();
        renderFeed(autoFilter || 'all');

        if (targetMsg) {
            requestAnimationFrame(() => { setTimeout(() => jumpToMessage(targetMsg), 500); });
        } else {
            window.scrollTo(0, 0);
        }
    } catch (err) {
        output.innerHTML = `<b style="color:red">DATA CORRUPTION: ${err.message}</b>`;
    }
}

function renderFeed(filterId) {
    const output = document.getElementById('viewer-output');
    if (!output) return;
    
    output.innerHTML = "";
    let lastRenderedChannelId = null;

    const logEntry = activeCampaign.logs.find(l => l.channelID === mainChannelId) || activeCampaign.logs[0];
    const displayTitle = (filterId === 'all') ? "Combined Feed" : (filterId === mainChannelId ? "Primary Feed" : window.channelMap[filterId]);
    updateBreadcrumb(logEntry.title, filterId !== 'all' ? displayTitle : null);

    const { messageId } = getUrlContext();
    const currentHashBase = filterId; 
    const newHash = messageId ? `${currentHashBase}:${messageId}` : currentHashBase;
    if (window.location.hash !== `#${newHash}`) {
        history.replaceState(null, null, `?c=${campaignSlug}#${newHash}`);
    }

    const isChannelNSFW = logEntry.isNSFW;

    fullData.forEach(msg => {
        // Surgical Fix: Use channel_id from Miner
        const actualChannel = msg.channel_id;
        let shouldShowContent = false;
        let shouldShowTransition = false;

        if (filterId === 'all') {
            shouldShowContent = true;
            shouldShowTransition = (actualChannel !== lastRenderedChannelId);
        } else if (filterId === mainChannelId) {
            if (actualChannel === mainChannelId) {
                shouldShowContent = true;
            } else {
                shouldShowTransition = (actualChannel !== lastRenderedChannelId);
            }
        } else {
            if (actualChannel === filterId) {
                shouldShowContent = true;
            } else if (actualChannel === mainChannelId) {
                shouldShowTransition = (actualChannel !== lastRenderedChannelId);
            }
        }

        if (shouldShowTransition && lastRenderedChannelId !== null) {
            const shiftName = window.channelMap[actualChannel] || "PRIMARY FREQUENCY";
            const transition = document.createElement('div');
            transition.className = 'channel-transition';
            transition.innerHTML = `📡 FREQUENCY SHIFT >> ${shiftName}`;
            transition.onclick = () => {
                renderFeed(actualChannel);
                requestAnimationFrame(() => { setTimeout(() => jumpToMessage(msg.id), 150); });
            };
            output.appendChild(transition);
        }

        if (shouldShowContent || shouldShowTransition) {
            lastRenderedChannelId = actualChannel;
        }

        if (shouldShowContent) {
            const threadRef = logEntry.threads ? logEntry.threads.find(t => t.threadID === msg.channel_id) : null;
            const isPostNSFW = detectNSFW(msg);
            const isCurrentMsgNSFW = isChannelNSFW || (threadRef && threadRef.isNSFW) || isPostNSFW;
            
            const isCurrentlyBlurred = isCurrentMsgNSFW && !window.GC_STATE.nsfwEnabled;
            const nsfwClass = isCurrentlyBlurred ? 'nsfw-blur' : (isCurrentMsgNSFW ? 'nsfw-blur off' : '');
            const nsfwBadge = isCurrentMsgNSFW ? `<span class="nsfw-badge" onclick="handleNSFWClick()">NSFW</span>` : '';

            const group = document.createElement('div');
            group.className = 'message-group';
            group.id = `msg-${msg.id}`;

            const avatarUrl = msg.author.avatar 
                ? `${remoteBase}${activeCampaign.paths.avatars}${msg.author.id}/${msg.author.avatar}.png` 
                : `${remoteBase}${activeCampaign.paths.avatars}default.png`;

            group.innerHTML = `
                <div class="avatar-container">
                    <img src="" data-src="${avatarUrl}" class="avatar lazy-load">
                </div>
                <div class="msg-body">
                    <div class="msg-header">
                        <span class="username">${msg.userName || msg.author.username}</span>
                        ${nsfwBadge}
                        <span class="timestamp">${new Date(msg.timestamp).toLocaleString()}</span>
                        <a href="javascript:void(0)" class="copy-link-icon" onclick="copyMsgLink(event, '${msg.id}', '${actualChannel}')">🔗</a>
                    </div>
                    <div class="msg-content ${nsfwClass}">${parseMarkdown(msg.content)}</div>
                    ${renderAttachments(msg, logEntry)} 
                    ${renderEmbeds(msg, logEntry)}
                </div>
            `;
            output.appendChild(group);
        }
    });
    silentLoadAvatars();
}

function parseMarkdown(text) {
    if (!text) return "";
    let html = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    const emojiBase = `${remoteBase}${activeCampaign.paths.emoji}`;
    const tripleTick = "\x60\x60\x60";
    const codeBlockRegex = new RegExp(tripleTick + '(?:[a-z]+)?\\n?([\\s\\S]+?)\\n?' + tripleTick, 'g');
    html = html.replace(codeBlockRegex, '<pre><code>$1</code></pre>');
    html = html.split('\n').map(line => line.startsWith('&gt; ') ? `<blockquote>${line.substring(5)}</blockquote>` : line).join('\n');
    html = html.replace(/^# (.*$)/gm, '<h1>$1</h1>').replace(/^## (.*$)/gm, '<h2>$1</h2>').replace(/^### (.*$)/gm, '<h3>$1</h3>').replace(/^#### (.*$)/gm, '<h4>$1</h4>').replace(/^##### (.*$)/gm, '<h5>$1</h5>').replace(/^###### (.*$)/gm, '<h6>$1</h6>').replace(/^-# (.*$)/gm, '<small class="subtext">$1</small>');
    
    html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (match, label, rawUrl) => {
        let cleanUrl = rawUrl.trim().replace(/^&lt;/, "").replace(/&gt;$/, "").replace(/&amp;/g, "&");
        return `<a href="${cleanUrl}" target="_blank" class="external-link">${label}</a>`;
    });

    html = html.replace(/(?:&lt;#(\d+)&gt;|https?:\/\/discord\.com\/channels\/\d+\/(\d+)(?:\/(\d+))?)/g, (match, mentionId, urlChanId, urlMsgId) => {
        const id = mentionId || urlChanId;
        const res = resolveInternalLinkData(id);
        if (res.found) {
            const targetHash = (res.filterId !== 'all') ? res.filterId : res.parentId;
            const jumpId = urlMsgId ? `:${urlMsgId}` : "";
            const href = `${window.site_baseurl}/logs?c=${res.slug}#${targetHash}${jumpId}`;
            const breadcrumb = `${res.isExternal ? res.campaignName + ' > ' : ''}${res.locationName}`;
            return `<a href="${href}" class="channel-link"># ${breadcrumb}${urlMsgId ? ' ✉️' : ''}</a>`;
        }
        return match;
    });

    const imgRegex = /(https?:\/\/[^\s<]+?\.(?:png|jpg|jpeg|gif|webp)[^\s<]*)/gi;
    html = html.replace(imgRegex, (url) => `<div class="attachment-item"><a href="${url}" target="_blank"><img src="${url}" class="log-image" loading="lazy"></a></div>`);
    
    // Vault Format Fix: !name!_id.png
    html = html.replace(/&lt;a?(:.*?:)(\d+)&gt;/g, (m, name, id) => `<img src="${emojiBase}!${name.replace(/:/g, '')}!_${id}.png" class="emoji" title="${name.replace(/:/g, '')}">`);
    
    return html.replace(/\*\*\*(.*?)\*\*\*/g, '<strong><i>$1</i></strong>').replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>').replace(/\*(.*?)\*/g, '<i>$1</i>').replace(/`(.*?)`/g, '<code>$1</code>').replace(/\|\|(.*?)\|\|/g, '<span class="spoiler" onclick="this.classList.toggle(\'revealed\')">$1</span>').replace(/\n/g, '<br>').replace(/<\/blockquote><br>/g, '</blockquote>').replace(/<\/pre><br>/g, '</pre>');
}

function resolveInternalLinkData(id) {
    for (let slug in registry.campaigns) {
        const camp = registry.campaigns[slug];
        const chapter = camp.logs.find(l => l.channelID === id);
        if (chapter) return { found: true, slug, parentId: id, filterId: 'all', locationName: chapter.title, campaignName: camp.name, isExternal: (slug !== campaignSlug) };
        const logWithThread = camp.logs.find(l => l.threads && l.threads.some(t => t.threadID === id));
        if (logWithThread) {
            const thread = logWithThread.threads.find(t => t.threadID === id);
            return { found: true, slug, parentId: logWithThread.channelID, filterId: id, locationName: `${logWithThread.title} > ${thread.displayName}`, campaignName: camp.name, isExternal: (slug !== campaignSlug) };
        }
    }
    return { found: false };
}

function updateBreadcrumb(chapterTitle, threadTitle = null) {
    const chapEl = document.getElementById('active-chapter-name');
    const threadEl = document.getElementById('thread-indicator');
    if (!chapEl) return;
    let displayChapter = chapterTitle;
    let limit = 100;
    if (window.innerWidth < 600) limit = 22;
    else if (window.innerWidth < 950) limit = 35;
    if (displayChapter.length > limit) displayChapter = displayChapter.substring(0, limit - 3) + "...";
    chapEl.innerHTML = `${displayChapter.toUpperCase()} <span style="font-size: 0.7em; opacity: 0.5; margin-left: 5px;">▼</span>`;
    if (threadEl) {
        if (threadTitle) {
            let displayThread = threadTitle;
            if (window.innerWidth < 600 && displayThread.length > 20) displayThread = displayThread.substring(0, 17) + "...";
            threadEl.style.display = 'flex';
            threadEl.innerHTML = `<span class="nav-arrow">❯</span><span>${displayThread.toUpperCase()}</span>`;
        } else {
            threadEl.style.display = 'none';
        }
    }
}

function toggleChapterList() {
    const dropdown = document.getElementById('chapter-list-dropdown');
    if (dropdown) dropdown.style.display = dropdown.style.display === 'block' ? 'none' : 'block';
}

function buildFrequencyBar() {
    const target = document.getElementById('freq-buttons-target');
    const toggleBtn = document.getElementById('thread-toggle');
    const uniqueChannels = [...new Set(fullData.map(m => m.channel_id))].filter(id => id !== mainChannelId);
    if (uniqueChannels.length === 0) {
        if (toggleBtn) toggleBtn.style.display = 'none';
        return; 
    }
    if (toggleBtn) toggleBtn.style.display = 'block';
    let html = `<div class="comms-status">📡 Encrypted Frequencies:</div><button class="freq-btn" onclick="renderFeed('all')">COMBINED</button><button class="freq-btn" onclick="renderFeed('${mainChannelId}')">PRIMARY ONLY</button>`;
    uniqueChannels.forEach(id => { 
        html += `<button class="freq-btn" onclick="renderFeed('${id}')">${window.channelMap[id] || "SUB-CHANNEL"}</button>`; 
    });
    if (target) target.innerHTML = html;
}

function toggleFrequencies() {
    const bar = document.getElementById('frequency-selector');
    if (bar) bar.style.display = (bar.style.display === 'none' || bar.style.display === '') ? 'block' : 'none';
}

function renderAttachments(msg, logRef) {
    if (!msg.attachments || msg.attachments.length === 0 || !logRef) return "";
    const folder = logRef.fileName.replace('.json', '');
    const mediaReg = window.GC_STATE.mediaRegistry || [];
    const isPostNSFW = detectNSFW(msg);
    let html = '<div class="msg-attachments">';
    msg.attachments.forEach(att => {
        const registryMatchPath = `${folder}/${att.filename}`;
        const src = `${window.GC_STATE.remoteBase}${window.GC_STATE.currentCampaign.paths.media}${folder}/${att.filename}`;
        const isFileNSFW = mediaReg.some(entry => entry.endsWith(registryMatchPath)) || isPostNSFW;
        const isImage = (att.content_type && att.content_type.startsWith('image/')) || /\.(jpg|jpeg|png|gif|webp)$/i.test(att.filename);
        if (isImage) {
            if (isFileNSFW && !window.GC_STATE.nsfwEnabled) {
                const warning = (window.GC_STATE.contentWarnings && window.GC_STATE.contentWarnings[registryMatchPath]) || "RESTRICTED DATA";
                html += `<div class="media-shield"><div class="shield-overlay"><span class="shield-icon">⚠</span><div class="shield-info"><span class="shield-label">ENCRYPTION ACTIVE</span><span class="shield-text">${warning.toUpperCase()}</span></div><button class="decrypt-btn" onclick="handleNSFWClick()">DECRYPT</button></div></div>`;
            } else {
                html += `<div class="attachment-item"><a href="${src}" target="_blank"><img src="${src}" class="log-image" loading="lazy"></a></div>`;
            }
        } else {
            html += `<div class="attachment-item"><a href="${src}" target="_blank" class="file-link">📄 ${att.filename}</a></div>`;
        }
    });
    return html + '</div>';
}

function renderEmbeds(msg, logRef) {
    if (!msg.embeds || msg.embeds.length === 0) return "";
    const folder = logRef.fileName.replace('.json', '');
    let html = '<div class="msg-embeds">';
    msg.embeds.forEach(embed => {
        if (embed.thumbnail && embed.thumbnail.url) {
            let src = embed.thumbnail.url;
            if (!src.startsWith('http')) src = `${remoteBase}${activeCampaign.paths.media}${folder}/${src}`;
            html += `<div class="embed-item"><a href="${embed.url || src}" target="_blank"><img src="${src}" class="log-image embed-img" loading="lazy"></a></div>`;
        }
    });
    return html + '</div>';
}

function jumpToMessage(msgId) {
    const target = document.getElementById(msgId.startsWith('msg-') ? msgId : `msg-${msgId}`);
    if (target) {
        target.scrollIntoView({ behavior: 'smooth', block: 'center' });
        target.classList.add('highlight-flash');
        setTimeout(() => target.classList.remove('highlight-flash'), 3000);
    }
}

function silentLoadAvatars() {
    document.querySelectorAll('.lazy-load').forEach(img => {
        const src = img.getAttribute('data-src');
        const probe = new Image();
        probe.src = src;
        probe.onload = () => { img.src = src; img.classList.add('loaded'); };
        probe.onerror = () => { img.src = `${remoteBase}${activeCampaign.paths.avatars}default.png`; };
    });
}

function copyMsgLink(event, msgId, actualChannel) {
    event.preventDefault();
    const url = `${window.location.origin}${window.site_baseurl}/logs?c=${window.GC_STATE.campaignSlug}#${actualChannel}:${msgId}`;
    navigator.clipboard.writeText(url).then(() => {
        const icon = event.target;
        const original = icon.innerText;
        icon.innerText = "COPIED";
        icon.style.color = "var(--sw-yellow)";
        setTimeout(() => { icon.innerText = original; icon.style.color = ""; }, 1500);
    });
}

document.addEventListener("DOMContentLoaded", init);
