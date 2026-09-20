{% if m.acl.is_admin and not m.acl.is_read_only %}
    {% wire id=#consumer type="submit" postback=`consumer_create` delegate=`mediarunner` %}
    <form id="{{ #consumer }}" method="post" action="postback">
        <p>{_ Create a separate user and OAuth2 key for a website that uses this media runner. _}</p>
        <div class="form-group">
            <label for="{{ #name }}">{_ Website / consumer name _}</label>
            <input id="{{ #name }}" class="form-control" type="text" name="name" required maxlength="128" autofocus autocomplete="off">
            {% validate id=#name name="name" type={presence} %}
        </div>
        <div class="modal-footer">
            {% button class="btn btn-default" text=_"Cancel" action={dialog_close} %}
            {% button class="btn btn-primary" type="submit" text=_"Create consumer" %}
        </div>
    </form>
{% endif %}
