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
// Fetch and render products belonging to the specific store
async function loadStoreProducts(storeId) {
    console.log("Loading products for store ID:", storeId);

    try {
        const { data: products, error } = await window.supabaseClient
            .from('products') // Products table in database
            .select('*')
            .eq('store_id', storeId);

        if (error) {
            console.error("Error fetching products:", error);
            return;
        }

        const productsContainer = document.getElementById('products-container');
        if (!productsContainer) return;

        productsContainer.innerHTML = '';

        if (!products || products.length === 0) {
            productsContainer.innerHTML = '<p>No products available in this store yet.</p>';
            return;
        }

        // Render each product dynamically
        products.forEach(product => {
            const productCard = document.createElement('div');
            productCard.className = 'product-card';
            productCard.innerHTML = `
                <img src="${product.image_url || 'default-product.png'}" alt="${product.name}" />
                <h3>${product.name}</h3>
                <p>${product.price} USD</p>
                <button onclick="addToCart('${product.id}')">Add to Cart</button>
            `;
            productsContainer.appendChild(productCard);
        });

    } catch (err) {
        console.error("Error loading products:", err);
    }
}
