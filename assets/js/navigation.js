// assets/js/navigation.js

window.GC_STATE = {
    registry: null,
    currentCampaign: null,
    campaignSlug: null,
    remoteBase: "",
    isReady: false,
    // --- NEW: NSFW & NAVIGATION STATE ---
    nsfwEnabled: localStorage.getItem('GC_NSFW_ENABLED') === 'true',
    mediaRegistry: null,
    lastScrollPos: 0,
    hasJumped: false
};

/**
 * Shared utility to fetch the registry once.
 */
async function getRegistry() {
    if (window.GC_STATE.registry) return window.GC_STATE.registry;
    try {
        // Added ?t= timestamp to bust cache
        const res = await fetch(`${window.site_baseurl}/assets/campaign-registry.json?t=${Date.now()}`);
        if (!res.ok) throw new Error("Registry network response was not ok");
        window.GC_STATE.registry = await res.json();
        return window.GC_STATE.registry;
    } catch (e) {
        console.error("Registry Load Failed:", e);
        return null;
    }
}


/**
 * Standardizes how we extract campaign and channel info from the URL
 */
function getUrlContext() {
    const params = new URLSearchParams(window.location.search);
    const hash = window.location.hash.substring(1);
    const [primaryHash, messageId] = hash.split(':');
    
    return {
        slug: params.get('c'),
        channelId: primaryHash || null,
        messageId: messageId || null
    };
}

/**
 * Updates the global Navbar and hydrates the GC_STATE.
 */
async function updateGlobalNav() {
    const registry = await getRegistry();
    const { slug } = getUrlContext();
    const dropdown = document.getElementById('campaign-dropdown');
    const brandText = document.getElementById('nav-brand-text');
    const flavorText = document.getElementById('flavor-text');
    
    if (!registry) return;

    // 1. Populate dropdown if empty (prevent duplicates)
    if (dropdown && dropdown.options.length <= 2) {
        Object.keys(registry.campaigns).forEach(s => {
            const opt = document.createElement('option');
            opt.value = s;
            opt.textContent = registry.campaigns[s].name;
            dropdown.appendChild(opt);
        });
    }

    if (dropdown && slug) dropdown.value = slug;

    if (slug && registry.campaigns[slug]) {
        const campaign = registry.campaigns[slug];
        window.GC_STATE.campaignSlug = slug;
        window.GC_STATE.currentCampaign = campaign;

        // Set the remoteBase for general assets (logos, avatars)
        let cleanDataPath = (campaign.dataPath || "").replace(/^\.\//, "");
        if (cleanDataPath && !cleanDataPath.endsWith('/')) cleanDataPath += '/';
        window.GC_STATE.remoteBase = `https://raw.githubusercontent.com/${campaign.repository}/${campaign.branch}/${cleanDataPath}`;

        // --- REUSABLE REGISTRY FETCH ---
        const mediaRegistryPath = getMediaRegistryPath(campaign);

        if (mediaRegistryPath) {
            console.log(`📡 Link Established: Fetching registry from ${mediaRegistryPath}`);
            try {
                // Append cache buster to the specific fetch
                const mediaResp = await fetch(`${mediaRegistryPath}?t=${Date.now()}`, { cache: "no-cache" });
                if (mediaResp.ok) {
                    const mediaData = await mediaResp.json();
                    window.GC_STATE.mediaRegistry = mediaData.nsfw_files || [];
                    window.GC_STATE.contentWarnings = mediaData.content_warnings || {};
                }
            } catch (e) {
                console.error("Failed to fetch remote media registry:", e);
            }
        } else {
            // Fallback if no registry is defined for this campaign
            console.log("ℹ️ No media registry defined for this frequency.");
            window.GC_STATE.mediaRegistry = [];
            window.GC_STATE.contentWarnings = {};
        }

        // --- UI UPDATES ---
        if (brandText) {
            brandText.textContent = campaign.name;
            brandText.href = `${window.site_baseurl}/?c=${slug}`;
        }

        if (flavorText) {
            flavorText.textContent = campaign.description || "Decrypting narrative stream...";
        }
        
        // Update navigation links
        document.querySelectorAll('.campaign-link').forEach(el => {
            el.style.display = 'inline-block';
            if (el.id === 'nav-archives') el.href = `${window.site_baseurl}/archives?c=${slug}`;
            
            if (el.id === 'nav-wiki') {
                if (campaign.paths && campaign.paths.wiki) {
                    el.href = campaign.paths.wiki;
                    el.style.display = 'inline-block';
                } else {
                    el.style.display = 'none';
                }
            }
        });

        // Logo Handling (handles root vs subfolder remote paths)
        const logoImg = document.getElementById('site-logo');
        if (logoImg) {
            logoImg.src = (campaign.paths && campaign.paths.logo) 
                ? `${window.GC_STATE.remoteBase}${campaign.paths.logo}` 
                : `${window.site_baseurl}/assets/gc_banner.png`;
        }

    } else {
        // --- FALLBACK (NO CAMPAIGN SELECTED) ---
        if (brandText) {
            brandText.textContent = "Galactic Campaigns";
            brandText.href = `${window.site_baseurl}/`;
        }
        if (flavorText) flavorText.textContent = "Select a frequency to begin decryption.";
        document.querySelectorAll('.campaign-link').forEach(el => el.style.display = 'none');
        
        // Reset states
        window.GC_STATE.mediaRegistry = [];
        window.GC_STATE.contentWarnings = {};
    }

    // Initialize UI states for NSFW (Blur toggle, etc)
    if (typeof syncNSFWUI === 'function') syncNSFWUI();

    window.GC_STATE.isReady = true;
    document.dispatchEvent(new CustomEvent('GCStateReady'));
    triggerLayoutReflow()
}

/**
 * Resolves the remote path for a campaign-specific media registry.
 * Returns null if the registry isn't defined in the manifest.
 */
function getMediaRegistryPath(campaign) {
    // 1. Check if the key exists and has a value
    if (!campaign.paths || !campaign.paths.mediaRegistry) {
        return null;
    }

    // 2. Normalize the dataPath (handles './' or 'subfolder/')
    let cleanDataPath = (campaign.dataPath || "").replace(/^\.\//, "");
    if (cleanDataPath && !cleanDataPath.endsWith('/')) cleanDataPath += '/';

    // 3. Construct the GitHub Raw URL
    const gitHubUrl = `https://raw.githubusercontent.com/${campaign.repository}/${campaign.branch}/${cleanDataPath}`;
    
    // 4. Return the full path to the registry file
    return `${gitHubUrl}${campaign.paths.mediaRegistry}?t=${Date.now()}`;
}

/**
 * Logic to handle NSFW toggle requests from UI components.
 * Forces a prompt for enabling, but allows instant disabling.
 */
function handleNSFWClick() {
    if (window.GC_STATE.nsfwEnabled) {
        toggleNSFW(); // Secure mode: Lock down immediately.
    } else {
        showProtocolOverride(); // Mature mode: Request authorization.
    }
}

function toggleNSFW() {
    window.GC_STATE.nsfwEnabled = !window.GC_STATE.nsfwEnabled;
    localStorage.setItem('GC_NSFW_ENABLED', window.GC_STATE.nsfwEnabled);
    syncNSFWUI();
    document.dispatchEvent(new CustomEvent('NSFWStateChanged'));
}

function syncNSFWUI() {
    const isEnabled = window.GC_STATE.nsfwEnabled;
    document.body.classList.toggle('nsfw-unlocked', isEnabled);
    
    document.querySelectorAll('.nsfw-blur').forEach(el => {
        el.classList.toggle('off', isEnabled);
    });

    const btn = document.getElementById('nsfw-toggle-btn');
    if (btn) {
        btn.textContent = isEnabled ? "FILTER: OFF (MATURE)" : "FILTER: ON (SECURE)";
        btn.classList.toggle('active', isEnabled);
        btn.setAttribute('onclick', 'handleNSFWClick()');
    }
}

function detectNSFW(msg) {
    // 1. Check for the manual override key from the script
    if (msg.isNSFW === true) return true;

    // 2. Check for the 🔞 reaction dynamically
    if (msg.reactions && msg.reactions.length > 0) {
        return msg.reactions.some(r => r.emoji.name === '🔞' || r.emoji.name === 'underage');
    }

    return false;
}

function showProtocolOverride() {
    let modal = document.getElementById('nsfw-gateway');
    if (!modal) {
        modal = document.createElement('div');
        modal.id = 'nsfw-gateway';
        modal.className = 'nsfw-gateway';
        modal.innerHTML = `
            <div class="gateway-content">
                <div class="terminal-header">SYSTEM ALERT: PROTOCOL OVERRIDE</div>
                <p>Sensitive data detected. Proceeding will bypass secure filters and expose mature content. Confirm authorization?</p>
                <div class="gateway-actions">
                    <button class="decrypt-btn" onclick="confirmNSFW()">EXECUTE OVERRIDE</button>
                    <button class="freq-btn" onclick="closeNSFWGateway()">ABORT</button>
                </div>
            </div>`;
        document.body.appendChild(modal);
    }
    modal.style.display = 'flex';
}

function closeNSFWGateway() {
    const modal = document.getElementById('nsfw-gateway');
    if (modal) modal.style.display = 'none';
}

function confirmNSFW() {
    if (!window.GC_STATE.nsfwEnabled) toggleNSFW();
    closeNSFWGateway();
}

/**
 * --- NEW: NAVIGATION HUD LOGIC ---
 */
function jumpToBottom() {
    window.GC_STATE.lastScrollPos = window.scrollY;
    window.GC_STATE.hasJumped = true;
    
    window.scrollTo({ top: document.body.scrollHeight, behavior: 'smooth' });
    updateHUDVisibility();
}

function jumpToTop() {
    window.scrollTo({ top: 0, behavior: 'smooth' });
}

function returnToPosition() {
    if (window.GC_STATE.hasJumped) {
        window.scrollTo({ top: window.GC_STATE.lastScrollPos, behavior: 'smooth' });
        window.GC_STATE.hasJumped = false;
        updateHUDVisibility();
    }
}

function updateHUDVisibility() {
    const returnBtn = document.getElementById('hud-return');
    if (returnBtn) {
        returnBtn.style.display = window.GC_STATE.hasJumped ? 'flex' : 'none';
    }
}

// Global click listener to close custom dropdowns
window.onclick = (e) => {
    if (!e.target.closest('.chapter-trigger')) {
        const d = document.getElementById('chapter-list-dropdown');
        if (d) d.style.display = 'none';
    }
};

function triggerLayoutReflow() {
    const { slug } = getUrlContext();
    if (!slug || !window.GC_STATE.currentCampaign) return;

    // 1. Handle Global Nav Truncation
    const brandText = document.getElementById('nav-brand-text');
    if (brandText) {
        let name = window.GC_STATE.currentCampaign.name;
        if (window.innerWidth < 450 && name.length > 20) {
            brandText.textContent = name.substring(0, 17) + "...";
        } else {
            brandText.textContent = name;
        }
    }

    // 2. Handle Log Viewer Breadcrumbs
    // Look for the function and the ID we stored in log.js
    if (typeof updateBreadcrumb === 'function' && window.GC_STATE.currentMainChannelId) {
        const activeLog = window.GC_STATE.currentCampaign.logs.find(
            l => l.channelID === window.GC_STATE.currentMainChannelId
        );
        
        if (activeLog) {
            const currentHash = window.location.hash.substring(1).split(':')[0] || 'all';
            
            // Resolve the thread name from the global map
            let threadName = null;
            if (currentHash === 'all') {
                threadName = "COMBINED FEED";
            } else if (currentHash === window.GC_STATE.currentMainChannelId) {
                threadName = "PRIMARY FEED";
            } else {
                threadName = window.channelMap[currentHash] || null;
            }

            // Trigger the re-draw with current window width logic
            updateBreadcrumb(activeLog.title, threadName);
        }
    }
}

// 2. Attach the Listener
window.addEventListener('resize', () => {
    // We use a small debounce so it doesn't fire 100 times during a rotation
    clearTimeout(window.GC_STATE.resizeTimer);
    window.GC_STATE.resizeTimer = setTimeout(triggerLayoutReflow, 150);
});

document.addEventListener("DOMContentLoaded", updateGlobalNav);