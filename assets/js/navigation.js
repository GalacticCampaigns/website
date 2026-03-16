// assets/js/navigation.js

window.GC_STATE = {
    registry: null,
    currentCampaign: null,
    campaignSlug: null,
    remoteBase: "",
    isReady: false // Track if state is fully hydrated
};

/**
 * Shared utility to fetch the registry once.
 */
async function getRegistry() {
    if (window.GC_STATE.registry) return window.GC_STATE.registry;
    try {
        // Use window.site_baseurl set in default.html
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
 * Updates the global Navbar (Branding, Dropdown, Links) 
 * and hydrates the GC_STATE for the active page.
 */
async function updateGlobalNav() {
    const registry = await getRegistry();
    const { slug } = getUrlContext();
    const dropdown = document.getElementById('campaign-dropdown');
    const brandText = document.getElementById('nav-brand-text');
    const flavorText = document.getElementById('flavor-text');
    
    if (!registry) return;

    // 1. Populate dropdown if empty (prevent double-populating)
    if (dropdown && dropdown.options.length <= 2) {
        Object.keys(registry.campaigns).forEach(s => {
            const opt = document.createElement('option');
            opt.value = s;
            opt.textContent = registry.campaigns[s].name;
            dropdown.appendChild(opt);
        });
    }

    // 2. Set Active State in Dropdown
    if (dropdown && slug) {
        dropdown.value = slug;
    }

    if (slug && registry.campaigns[slug]) {
        const campaign = registry.campaigns[slug];
        window.GC_STATE.campaignSlug = slug;
        window.GC_STATE.currentCampaign = campaign;
        
        // Setup Remote Base for assets
        const cleanPath = (campaign.dataPath || "").replace(/^\.\//, "").replace(/\/$/, "");
        window.GC_STATE.remoteBase = `https://raw.githubusercontent.com/${campaign.repository}/${campaign.branch}/${cleanPath ? cleanPath + '/' : ''}`;

        // Update Nav Branding
        if (brandText) {
            brandText.textContent = campaign.name;
            brandText.href = `${window.site_baseurl}/?c=${slug}`;
        }

        // Update Flavor Text
        if (flavorText) {
            flavorText.textContent = campaign.description || "Decrypting narrative stream...";
        }
        
        // Show/Update Campaign Links
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

        // Update Banner/Logo
        const logoImg = document.getElementById('site-logo');
        if (logoImg) {
            logoImg.src = (campaign.paths && campaign.paths.logo) 
                ? `${window.GC_STATE.remoteBase}${campaign.paths.logo}` 
                : `${window.site_baseurl}/assets/gc_banner.png`;
        }
    } else {
        // Hub/Default Reset
        if (brandText) {
            brandText.textContent = "Galactic Campaigns";
            brandText.href = `${window.site_baseurl}/`;
        }
        if (flavorText) flavorText.textContent = "Select a frequency to begin decryption.";
        document.querySelectorAll('.campaign-link').forEach(el => el.style.display = 'none');
    }

    window.GC_STATE.isReady = true;
    // Dispatch custom event so individual pages know state is ready
    document.dispatchEvent(new CustomEvent('GCStateReady'));
}