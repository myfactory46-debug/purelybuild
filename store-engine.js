// Extract store slug from subdomain or path
function getStoreSlug() {
    const hostname = window.location.hostname;
    const parts = hostname.split('.');
    
    if (parts.length > 2 && parts[0] !== 'www') {
        return parts[0];
    }
    
    const urlParams = new URLSearchParams(window.location.search);
    return urlParams.get('store') || 'default-store';
}

// Fetch store data from Supabase and render it dynamically
async function loadStorefront() {
    const storeSlug = getStoreSlug();
    console.log("Loading store for slug:", storeSlug);

    try {
        const { data, error } = await window.supabaseClient
            .from('stores')
            .select('*')
            .eq('slug', storeSlug)
            .single();

        if (error || !data) {
            document.body.innerHTML = `<h1 style="text-align:center; margin-top:20vh;">Store not found or closed 🚫</h1>`;
            return;
        }

        document.getElementById('store-title').innerText = data.store_name;
        document.getElementById('store-logo').src = data.logo_url || 'default-logo.png';
        
        loadStoreProducts(data.id);

    } catch (err) {
        console.error("Error fetching store data:", err);
    }
}

window.addEventListener('DOMContentLoaded', loadStorefront);
