{% if m.acl.is_admin and not m.acl.is_read_only %}
    <p><strong>{{ consumer.name|escape }}</strong></p>
    <p>{_ The new user can submit media jobs and access its own cached files. It has no administration permissions. _}</p>
    <div class="form-group">
        <label for="{{ #key }}">{_ OAuth2 key _}</label>
        <textarea id="{{ #key }}" class="form-control" rows="5" readonly autocomplete="off" spellcheck="false">{{ consumer.token|escape }}</textarea>
    </div>
    <button type="button" class="btn btn-primary" data-onclick-topic="model/clipboard/post/copy" data-text="{{ consumer.token|escape }}">
        <span class="fa fa-copy" aria-hidden="true"></span> {_ Copy key _}
    </button>
    <p class="help-block">{_ Save this key securely. It is only shown here once. _}</p>
    <p>{_ Use this key for _} <code>media_runner_oauth2_key</code> {_ on the client website. You can revoke it in the OAuth2 clients administration. _}</p>
{% endif %}
<div class="modal-footer">
    {% button class="btn btn-default" text=_"Close" action={reload} %}
</div>
