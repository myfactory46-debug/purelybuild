document.addEventListener('DOMContentLoaded', async () => {
  const urlParams = new URLSearchParams(window.location.search);
  const storeSlug = urlParams.get('store');

  if (!storeSlug) return;

  const supabase = window.supabaseClient;
  if (!supabase) {
    console.error('Supabase client not initialized');
    return;
  }

  try {
    const { data: storeData, error: storeError } = await supabase
      .from('stores')
      .select('*')
      .eq('slug', storeSlug)
      .single();

    if (storeError || !storeData) {
      console.error('Store not found');
      return;
    }

    document.title = storeData.store_name;
    const storeTitleEl = document.getElementById('store-title');
    if (storeTitleEl) storeTitleEl.textContent = storeData.store_name;

    const { data: productsData, error: productsError } = await supabase
      .from('products')
      .select('*')
      .eq('store_id', storeData.id);

    if (productsError) {
      console.error('Error fetching products');
      return;
    }

    const container = document.getElementById('products-container');
    if (!container) return;

    container.innerHTML = '';

    if (productsData && productsData.length > 0) {
      productsData.forEach(product => {
        const card = document.createElement('div');
        card.className = 'bg-slate-900 border border-slate-800 p-6 rounded-xl text-left shadow-lg';
        card.innerHTML = `
          <h3 class="text-lg font-bold text-white mb-2">${product.name}</h3>
          <p class="text-emerald-400 font-semibold text-xl mb-4">$${product.price}</p>
          <button class="w-full bg-blue-600 hover:bg-blue-500 text-white py-2 px-4 rounded-lg text-sm transition">Buy Now</button>
        `;
        container.appendChild(card);
      });
    } else {
      container.innerHTML = '<p class="text-slate-400 col-span-full">No products available in this store yet.</p>';
    }

  } catch (err) {
    console.error('Unexpected error:', err);
  }
});
