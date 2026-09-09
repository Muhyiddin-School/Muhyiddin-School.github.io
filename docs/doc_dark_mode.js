// DarkPage

			if (localStorage.getItem('docDarkMode') === 'true') {
				setDark();
				document.getElementById('darkModeToggle').checked = true;
			}  else {
				setLight();
				document.getElementById('darkModeToggle').checked = false;
			}

			document.getElementById('darkModeToggle').addEventListener('change',  function() {
				if (this.checked) {
					setDark();
				} else {
					setLight();
				}
			});
			
			function setDark() {
				var docPage = document.getElementById('doc_page');
				var docContent =  document.querySelectorAll('.doc_content');
				var docButton =  document.querySelectorAll('.doc_button');
				
				docPage.style.color = '#ffffff';
				docPage.style.background = '#252525'; 
					
					
					docContent.forEach(function(element) {
						element.style.color = '#ffffff';
						element.style.borderColor = '#ffffff';
					});
					
					docButton.forEach(function(element) {
						element.style.color = '#ffffff';
						element.style.borderColor = '#ffffff';
					});
					
				localStorage.setItem('docDarkMode', true);
			}
			
			function setLight() {
				var docPage = document.getElementById('doc_page');
				var docContent =  document.querySelectorAll('.doc_content');
				var docButton =  document.querySelectorAll('.doc_button');
				
				docPage.style.color = '#000000'; 
				docPage.style.background = '#ffffff';
					
					docContent.forEach(function(element) {
						element.style.color = '#000000';
						element.style.borderColor = '#000000';
					});
					
					docButton.forEach(function(element) {
						element.style.color = '#000000';
						element.style.borderColor = '#000000';
					});
					
				localStorage.setItem('docDarkMode', false);
			}			
			