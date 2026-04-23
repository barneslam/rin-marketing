import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY')!;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const sb = createClient(SUPABASE_URL, SERVICE_KEY);

  // Pull last 7 days of events + all leads
  const since = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();

  const [eventsRes, leadsRes] = await Promise.all([
    sb.from('ui_events').select('event_type, event_data, created_at').gte('created_at', since).order('created_at', { ascending: false }).limit(2000),
    sb.from('marketing_leads').select('company_name, inquiry_type, truck_count, status, created_at').gte('created_at', since).order('created_at', { ascending: false }),
  ]);

  const events = eventsRes.data ?? [];
  const leads  = leadsRes.data ?? [];

  // Aggregate stats
  const sessions    = new Set(events.map((e: any) => e.session_id)).size;
  const pageViews   = events.filter((e: any) => e.event_type === 'page_view').length;
  const formStarts  = events.filter((e: any) => e.event_type === 'form_start').length;
  const formSuccess = events.filter((e: any) => e.event_type === 'form_success').length;

  const sectionViews: Record<string, number> = {};
  events.filter((e: any) => e.event_type === 'section_view').forEach((e: any) => {
    const s = e.event_data?.section ?? 'unknown';
    sectionViews[s] = (sectionViews[s] ?? 0) + 1;
  });

  const ctaClicks: Record<string, number> = {};
  events.filter((e: any) => e.event_type === 'cta_click').forEach((e: any) => {
    const l = e.event_data?.label ?? 'unknown';
    ctaClicks[l] = (ctaClicks[l] ?? 0) + 1;
  });

  const scrollDepths: Record<string, number> = {};
  events.filter((e: any) => e.event_type === 'scroll_depth').forEach((e: any) => {
    const d = String(e.event_data?.depth_pct ?? 0);
    scrollDepths[d] = (scrollDepths[d] ?? 0) + 1;
  });

  const avgDwell: Record<string, number[]> = {};
  events.filter((e: any) => e.event_type === 'section_leave').forEach((e: any) => {
    const s = e.event_data?.section ?? 'unknown';
    const t = e.event_data?.dwell_seconds ?? 0;
    if (!avgDwell[s]) avgDwell[s] = [];
    avgDwell[s].push(t);
  });
  const dwellAvg: Record<string, number> = {};
  Object.entries(avgDwell).forEach(([s, times]) => {
    dwellAvg[s] = Math.round(times.reduce((a, b) => a + b, 0) / times.length);
  });

  const summary = {
    period: 'Last 7 days',
    unique_sessions: sessions,
    page_views: pageViews,
    form_starts: formStarts,
    form_completions: formSuccess,
    conversion_rate: formStarts > 0 ? `${Math.round((formSuccess / formStarts) * 100)}%` : '0%',
    section_views: sectionViews,
    cta_clicks: ctaClicks,
    scroll_depth_distribution: scrollDepths,
    avg_dwell_seconds_by_section: dwellAvg,
    total_leads: leads.length,
    leads_by_inquiry_type: leads.reduce((acc: any, l: any) => {
      acc[l.inquiry_type ?? 'unknown'] = (acc[l.inquiry_type ?? 'unknown'] ?? 0) + 1;
      return acc;
    }, {}),
  };

  // Ask Claude for insights
  const claudeRes = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'x-api-key': ANTHROPIC_KEY,
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      model: 'claude-sonnet-4-6',
      max_tokens: 1024,
      messages: [{
        role: 'user',
        content: `You are analyzing RIN (Roadside Intelligence Network) marketing website performance.

Here is the activity summary for the last 7 days:
${JSON.stringify(summary, null, 2)}

Provide a concise marketing intelligence report with:
1. **What's working** — highest-engagement sections and CTAs
2. **Drop-off risks** — where users lose interest or abandon
3. **Conversion analysis** — form start → completion rate insight
4. **Top 3 actionable recommendations** to improve lead capture
5. **Lead quality signal** — which inquiry types are most common

Keep it executive-brief. Use bullet points. Under 400 words.`,
      }],
    }),
  });

  const claudeData = await claudeRes.json();
  const analysis = claudeData.content?.[0]?.text ?? 'Analysis unavailable.';

  return new Response(JSON.stringify({ summary, analysis }), {
    headers: { ...corsHeaders, 'content-type': 'application/json' },
  });
});
