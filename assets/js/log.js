// assets/js/log.js

// --- 1. GLOBAL STATE ---
let fullData = [];
window.channelMap = {}; // CHANGE: Attach to window
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
    // If we don't have data loaded yet, don't try to render
    if (!fullData || fullData.length === 0) return;
    
    // Get current context so we don't lose our place
    const { channelId } = getUrlContext();
    const currentHash = window.location.hash.substring(1).split(':')[0] || 'all';
    
    // Re-render the feed to swap shields for images
    renderFeed(currentHash);
});
// Update HUD visibility on scroll
window.addEventListener('scroll', () => {
    if (window.GC_STATE.hasJumped) {
        // If user manually scrolls back near their original position, hide the return button
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
    const displayTitle = (filterId === 'all') ? "Combined Feed" : (filterId === mainChannelId ? "Primary Feed" : channelMap[filterId]);
    updateBreadcrumb(logEntry.title, filterId !== 'all' ? displayTitle : null);

    const validTypes = [0, 19, 18];
    const filteredTimeline = fullData.filter(m => validTypes.includes(m.type));

    // Update URL Hash
    const { messageId } = getUrlContext();
    const currentHashBase = filterId; 
    const newHash = messageId ? `${currentHashBase}:${messageId}` : currentHashBase;
    if (window.location.hash !== `#${newHash}`) {
        history.replaceState(null, null, `?c=${campaignSlug}#${newHash}`);
    }

    const isChannelNSFW = logEntry.isNSFW;

    filteredTimeline.forEach(msg => {
        const isThreadStarter = (msg.thread && msg.thread.id === mainChannelId);
        const actualChannel = isThreadStarter ? msg.thread.id : msg.channel_id;
        
        let shouldShowContent = false;
        let shouldShowTransition = false;

        // --- View Logic ---
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

        // --- Frequency Shift Logic ---
        if (shouldShowTransition && lastRenderedChannelId !== null) {
            const shiftName = channelMap[actualChannel] || "PRIMARY FREQUENCY";
            const transition = document.createElement('div');
            transition.className = 'channel-transition';
            transition.innerHTML = `📡 FREQUENCY SHIFT >> ${shiftName}`;
            
            // THE FIX: Always switch the feed, then jump, even if currently in 'all'
            transition.onclick = () => {
                // 1. Change the filter to the target channel/thread
                renderFeed(actualChannel);
                
                // 2. Queue the jump for after the DOM is rebuilt
                requestAnimationFrame(() => {
                    // A small timeout ensures the browser has rendered the 
                    // specific message element before we try to scroll to it.
                    setTimeout(() => jumpToMessage(msg.id), 150);
                });
            };
            output.appendChild(transition);
        }

        if (shouldShowContent || shouldShowTransition) {
            lastRenderedChannelId = actualChannel;
        }

        if (msg.type === 18 && msg.thread) {
            const anchor = document.createElement('div');
            anchor.className = 'thread-anchor-header';
            anchor.innerHTML = `
                <div class="anchor-line"></div>
                <div class="anchor-content">
                    <span class="anchor-icon">🧵</span>
                    <span class="anchor-title">SCENE START: ${msg.thread.name.toUpperCase()}</span>
                    <span class="anchor-date">${new Date(msg.timestamp).toLocaleDateString()}</span>
                </div>
            `;
            output.appendChild(anchor);
            return; // Don't render a chat bubble for the system message
        }

        // --- Message Rendering ---
        if (shouldShowContent) {
            const threadRef = logEntry.threads ? logEntry.threads.find(t => t.threadID === msg.channel_id) : null;

            // Rendering conditions for NSFW
            const isPostNSFW = detectNSFW(msg);
            const isCurrentMsgNSFW = isChannelNSFW || (threadRef && threadRef.isNSFW) || isPostNSFW;
            
            const isCurrentlyBlurred = isCurrentMsgNSFW && !window.GC_STATE.nsfwEnabled;
            const nsfwClass = isCurrentlyBlurred ? 'nsfw-blur' : (isCurrentMsgNSFW ? 'nsfw-blur off' : '');
            const nsfwBadge = isCurrentMsgNSFW 
                ? `<span class="nsfw-badge" style="cursor:pointer; margin-left:8px;" onclick="handleNSFWClick()">NSFW</span>` 
                : '';

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
                        <span class="username">${msg.author.nickname || msg.author.global_name || msg.author.username}</span>
                        ${nsfwBadge}
                        <span class="timestamp">${new Date(msg.timestamp).toLocaleString()}</span>
                        <a href="javascript:void(0)" class="copy-link-icon" onclick="copyMsgLink(event, '${msg.id}', '${actualChannel}')">🔗</a>
                    </div>
                    <div class="msg-content ${nsfwClass}">${parseMarkdown(msg.content)}</div>
                    ${renderAttachments(msg, logEntry)} 
                    ${renderEmbeds(msg, logEntry)}   <-- ADD THIS LINE
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

    // --- DYNAMIC TRUNCATION ---
    let displayChapter = chapterTitle;
    let limit = 100; // Default for Desktop

    if (window.innerWidth < 600) {
        limit = 22; // Portrait Mobile (Stacked)
    } else if (window.innerWidth < 950) {
        limit = 35; // Landscape Mobile / Tablet (Inline)
    }

    if (displayChapter.length > limit) {
        displayChapter = displayChapter.substring(0, limit - 3) + "...";
    }

    // Update Chapter
    chapEl.innerHTML = `${displayChapter.toUpperCase()} <span style="font-size: 0.7em; opacity: 0.5; margin-left: 5px;">▼</span>`;
    
    // Update Thread
    if (threadEl) {
        if (threadTitle) {
            let displayThread = threadTitle;
            if (window.innerWidth < 600 && displayThread.length > 20) {
                displayThread = displayThread.substring(0, 17) + "...";
            }
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
    const bar = document.getElementById('frequency-selector');
    const target = document.getElementById('freq-buttons-target');
    const toggleBtn = document.getElementById('thread-toggle');
    const uniqueChannels = [...new Set(fullData.map(m => m.channel_id))].filter(id => id !== mainChannelId);
    
    if (uniqueChannels.length === 0) { 
        if (bar) bar.style.display = 'none'; 
        if (toggleBtn) toggleBtn.style.display = 'none'; 
        return; 
    }
    
    if (toggleBtn) toggleBtn.style.display = 'block';

    // Added PRIMARY button specifically
    let html = `
        <div class="comms-status">📡 Encrypted Frequencies:</div>
        <button class="freq-btn" onclick="renderFeed('all')">COMBINED</button>
        <button class="freq-btn" onclick="renderFeed('${mainChannelId}')">PRIMARY ONLY</button>
    `;
    
    uniqueChannels.forEach(id => { 
        html += `<button class="freq-btn" onclick="renderFeed('${id}')">${channelMap[id] || "SUB-CHANNEL"}</button>`; 
    });
    
    if (target) target.innerHTML = html;
}

function toggleFrequencies() {
    const bar = document.getElementById('frequency-selector');
    if (bar) bar.style.display = (bar.style.display === 'none' || bar.style.display === '') ? 'block' : 'none';
}

// --- 7. UTILITIES & NSFW ---
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

        // FIXED: Check extension if content_type is null
        const isImage = (att.content_type && att.content_type.startsWith('image/')) || 
                        /\.(jpg|jpeg|png|gif|webp)$/i.test(att.filename);

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
        // We primarily care about image/video embeds and those with thumbnails
        if (embed.thumbnail && embed.thumbnail.url) {
            let src = embed.thumbnail.url;
            
            // If the refinery local-pathed this, it will start with 'media/' or the relative root
            // We need to ensure it's a full URL for the browser
            if (!src.startsWith('http')) {
                src = `${window.GC_STATE.remoteBase}${window.GC_STATE.currentCampaign.paths.media}${src}`;
            }

            html += `
                <div class="embed-item">
                    <a href="${embed.url || src}" target="_blank">
                        <img src="${src}" class="log-image embed-img" loading="lazy">
                    </a>
                </div>`;
        }
    });
    return html + '</div>';
}

function jumpToMessage(msgId) {
    const cleanId = msgId.startsWith('msg-') ? msgId : `msg-${msgId}`;
    const target = document.getElementById(cleanId);
    
    if (target) {
        // Scroll to the element
        target.scrollIntoView({ behavior: 'smooth', block: 'center' });
        
        // Add a "Ping" effect (CSS animation)
        target.classList.add('highlight-flash');
        
        // Remove highlight after a few seconds
        setTimeout(() => {
            target.classList.remove('highlight-flash');
        }, 3000);
    } else {
        console.warn(`Jump failed: ${cleanId} not found in current feed.`);
    }
}

function silentLoadAvatars() {
    document.querySelectorAll('.lazy-load').forEach(img => {
        const src = img.getAttribute('data-src');
        const probe = new Image();
        probe.src = src;
        probe.onload = () => { img.src = src; img.classList.add('loaded'); };
        probe.onerror = () => { img.src = `${remoteBase}${activeCampaign.paths.avatars}default.png`; img.classList.add('loaded'); };
    });
}

function copyMsgLink(event, msgId, actualChannel) {
    event.preventDefault();
    
    // 1. Ensure we use the current campaign slug from the global state
    const slug = window.GC_STATE.campaignSlug;
    
    // 2. Construct the "Snub" (The specific frequency + message ID)
    // actualChannel is passed from renderFeed and is already the correct ID
    const snub = `${actualChannel}:${msgId}`;
    
    // 3. Build the absolute URL
    const url = `${window.location.origin}${window.site_baseurl}/logs?c=${slug}#${snub}`;
    
    // 4. Copy to Clipboard
    navigator.clipboard.writeText(url).then(() => {
        const icon = event.target;
        const original = icon.innerText;
        icon.innerText = "COPIED";
        
        // Visual feedback
        icon.style.color = "var(--sw-yellow)";
        setTimeout(() => {
            icon.innerText = original;
            icon.style.color = "";
        }, 1500);
    }).catch(err => {
        console.error("Link capture failed:", err);
    });
}

document.addEventListener("DOMContentLoaded", init);