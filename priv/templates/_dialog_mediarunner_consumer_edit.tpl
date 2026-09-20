{% if m.acl.is_admin and not m.acl.is_read_only %}
    {% wire id=#edit type="submit" postback={consumer_update id=consumer.id} delegate=`mediarunner` %}
    <form id="{{ #edit }}" method="post" action="postback">
        <div class="form-group">
            <label for="{{ #name }}">{_ Website / consumer name _}</label>
            <input id="{{ #name }}" class="form-control" name="name" type="text" value="{{ consumer.description|escape }}" required maxlength="128" autofocus>
            {% validate id=#name name="name" type={presence} %}
        </div>
        <div class="checkbox">
            <label><input type="checkbox" name="rotate" value="1"> {_ Generate a new OAuth2 key _}</label>
        </div>
        <p class="help-block">{_ Generating a new key immediately revokes all existing keys for this consumer. Copy the new key to the client website after saving. _}</p>
        <div class="modal-footer">
            {% button class="btn btn-default" text=_"Cancel" action={dialog_close} %}
            {% button class="btn btn-primary" type="submit" text=_"Save" %}
        </div>
    </form>
{% endif %}
