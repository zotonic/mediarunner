{% extends "admin_base.tpl" %}
{% block title %}{_ Media runner _}{% endblock %}
{% block bodyclass %}mediarunner{% endblock %}
{% block head_extra %}{% lib "css/mediarunner.css" %}{% endblock %}
{% block navigation %}
<nav class="mr-nav" aria-label="{_ Main navigation _}">
    <a href="{% url mediarunner_dashboard %}" class="mr-brand"><span aria-hidden="true">▧</span> {_ Media runner _}</a>
    <a href="{% url admin_oauth2_apps %}">{_ OAuth2 clients _}</a>
    <a href="{% url admin %}">{_ Site administration _}</a>
    <a href="{% url logoff %}">{_ Log out _}</a>
</nav>
{% endblock %}
{% block content %}
<main id="mediarunner" class="mr-dashboard">
    <header class="mr-heading">
        <div><p class="mr-eyebrow">{_ PROCESSING OPERATIONS _}</p><h1>{_ Queue overview _}</h1>
            <p>{_ Sandboxed media processing and result delivery _}</p></div>
        <div class="mr-refresh"><p id="mr-freshness" role="status" aria-live="polite">{_ Connecting… _}</p>
            <button id="mr-refresh" type="button">{_ Refresh now _}</button>
            <label><input id="mr-live" type="checkbox" checked> {_ Auto-refresh every 10 seconds _}</label></div>
    </header>
    <p id="mr-error" class="mr-alert" role="alert" hidden>{_ Updates are unavailable. Last received data remains visible. _}</p>
    <section class="mr-metrics" aria-label="{_ Queue status _}">
        <article><h2>{_ Waiting _}</h2><strong id="mr-queued">—</strong><p>{_ Jobs ready to process _}</p></article>
        <article><h2>{_ Running _}</h2><strong id="mr-running">—</strong><p><span id="mr-workers">—</span> {_ worker slots _}</p></article>
        <article><h2>{_ Completed _}</h2><strong id="mr-completed">—</strong><p>{_ In the last 24 hours _}</p></article>
        <article><h2>{_ Needs attention _}</h2><strong id="mr-attention">—</strong><p>{_ Processing or delivery failures, last 24 hours _}</p></article>
    </section>
    <div class="mr-charts">
        <section class="mr-panel mr-throughput"><div class="mr-panel-heading"><h2>{_ Processing throughput _}</h2><span>{_ Last 24 hours · jobs per hour _}</span></div>
            <h3>{_ Completed jobs per hour (UTC) _}</h3>
            <div id="mr-throughput-completed" class="mr-throughput-chart"></div>
            <h3>{_ Failed jobs per hour (UTC) _}</h3>
            <div id="mr-throughput-failed" class="mr-throughput-chart"></div>
            <details><summary>{_ View chart data _}</summary><div class="mr-table-scroll"><table id="mr-chart-table"><thead><tr><th>{_ Hour (UTC) _}</th><th>{_ Completed _}</th><th>{_ Failed _}</th></tr></thead><tbody id="mr-chart-data"></tbody></table></div></details>
        </section>
        <section class="mr-panel"><h2>{_ Result delivery _}</h2><p>{_ Pending callbacks and outcomes from the last 24 hours _}</p>
            <div id="mr-delivery" class="mr-delivery"></div>
            <p class="mr-note">{_ Failed callbacks retry automatically until the job deadline or retry limit. _}</p>
        </section>
    </div>
    <section class="mr-panel mr-cache-panel" aria-label="{_ Media cache _}">
        <div><h2>{_ Media cache _}</h2><p>{_ Sources and successful results · least recently used entries are evicted first _}</p></div>
        <div><strong id="mr-cache-size">—</strong><p><span id="mr-cache-items">—</span> {_ cached items _}</p></div>
        <meter id="mr-cache-meter" min="0" max="1" value="0" aria-label="{_ Cache capacity used _}"></meter>
    </section>
    <section class="mr-panel mr-jobs">
        <div class="mr-panel-heading"><div><h2>{_ Jobs _}</h2><p>{_ Up to 100 jobs · active jobs first · history retained for 7 days _}</p></div>
            <label>{_ Show _} <select id="mr-filter">
                <option value="">{_ All jobs _}</option><option value="queued">{_ Waiting _}</option>
                <option value="running">{_ Running _}</option><option value="completed">{_ Completed _}</option>
                <option value="failed">{_ Processing or delivery failed _}</option><option value="pending">{_ Callback pending _}</option>
            </select></label></div>
        <div class="mr-table-scroll"><table><thead><tr><th>{_ Job _}</th><th>{_ Processor _}</th><th>{_ Status _}</th><th>{_ Created _}</th><th>{_ Duration _}</th><th>{_ Delivery _}</th><th>{_ Attempts _}</th></tr></thead><tbody id="mr-jobs"></tbody></table></div>
        <p id="mr-empty" hidden>{_ No jobs match this view. _}</p>
    </section>
    <div id="mr-labels" hidden>
        <span data-key="starting">{_ Waiting for capacity _}</span>
        <span data-key="queued">{_ Waiting _}</span><span data-key="running">{_ Running _}</span>
        <span data-key="completed">{_ Completed _}</span><span data-key="failed">{_ Failed _}</span>
        <span data-key="pending">{_ Pending _}</span><span data-key="sending">{_ Sending _}</span>
        <span data-key="waiting">{_ Awaiting processing _}</span><span data-key="delivered">{_ Delivered _}</span>
        <span data-key="expired">{_ Expired _}</span><span data-key="updated">{_ Updated _}</span>
        <span data-key="cached">{_ Cached result _}</span>
        <span data-key="paused">{_ Auto-refresh paused _}</span>
    </div>
</main>
{% endblock %}
{% block js_extra %}{% lib "js/mediarunner.js" %}{% endblock %}
